# Job claiming was not race-safe

**Status:** fixed · **Code:** `DistributedTaskQueue.claim_job/2` in `lib/distributed_task_queue.ex` · **Tests:** `test/distributed_task_queue/claim_concurrency_test.exs`

## How it was found

Not by an outage. By trying to answer a direct question: *walk through the exact lock that stops two nodes claiming job #47.* The honest answer turned out to be "nothing does."

Everything below was measured against real, separate PostgreSQL connections, not reasoned about.

## The original bug

The claim was a single statement:

```sql
UPDATE jobs AS j0 SET worker_id = ..., status = 'started'
 WHERE j0.id IN (SELECT sj0.id FROM jobs AS sj0
                  WHERE sj0.worker_id IS NULL AND ... LIMIT 1)
```

The outer `UPDATE` qualified on `id IN (subquery)` and nothing else. Every guard (`worker_id IS NULL`, status, schedule) lived in the subquery, which scans `jobs` under a **different range-table entry** — `sj0`, not `j0`.

Under `READ COMMITTED`, an `UPDATE` that blocks on another transaction's row lock re-evaluates its `WHERE` clause against the newly committed version of the row (EvalPlanQual). But that substitution applies only to the relation the `UPDATE` targets. The subquery re-ran against the **old snapshot**, still returned 47, so the qualifier passed and the second claimer updated the row anyway.

### Reproducing it

Forced interleaving — connection A runs the claim and holds its transaction open, B issues the same statement and blocks, then A commits:

```
A returned: [[5, 1, "nodeA"]]
B returned: [[5, 2, "nodeB"]]
final row:  [[5, 2, "nodeB"]]
verdict:    BOTH CLAIMED -> job runs twice
```

Both `QueueManager`s received `{:ok, job}` and both spawned `Worker.run_job`. Worse, `attempted_by` kept only the second writer — **the duplicate left no trace in the data.** A post-hoc audit of the `jobs` table would have shown a single, clean claim.

## The fix that didn't work

The first attempt added `FOR UPDATE SKIP LOCKED` to the subquery and repeated the guard on the outer `UPDATE`. It fixed the double-claim — and introduced a worse bug, caught by the new concurrency test:

```
rows=[{2364,"started",5},{2365,"started",1},{2366,"started",1},{2367,"started",3},{2368,"started",2}]
claimed=[2368, 2367, 2364]
```

Worker 1 marked **two** rows `started` in one statement (2365 and 2366), but only three ids came back to callers.

PostgreSQL may evaluate that subplan once per candidate row, and `SKIP LOCKED` makes its result depend on which rows happen to be locked at that instant. Successive evaluations returned different ids, so several rows matched `id IN (...)`. `claim_job` pattern-matched on a single row, so a two-row result fell through to `{:error, :no_jobs}` — and both rows were **stranded in `started` with nobody running them.** No worker owned them, and nothing in the system reclaims a `started` job.

That is strictly worse than the original bug: a duplicate run is visible to whoever the job affects; a job silently parked in `started` is not.

**Lesson:** a locking, `LIMIT`-ed subquery inside `IN (...)` is not safe unless you can guarantee it is evaluated exactly once. A `WITH ... AS MATERIALIZED` CTE would also have worked; the transaction below is easier to reason about and to verify.

## What shipped

Select-then-update inside a transaction:

```elixir
def claim_job(queue_name, worker_id) do
  now = DateTime.utc_now()
  attempted_by = "#{Node.self()}:#{queue_name}"

  Repo.transaction(fn ->
    case Repo.one(claimable_job_query(queue_name, now)) do   # ORDER BY inserted_at LIMIT 1
      nil -> Repo.rollback(:no_jobs)                         # FOR UPDATE SKIP LOCKED
      id -> mark_claimed(id, worker_id, attempted_by, now)   # UPDATE ... WHERE id = ^id
    end
  end)
end
```

- `FOR UPDATE SKIP LOCKED` locks the row during the `SELECT`, so a concurrent claimer steps over it and takes the next row instead of blocking. N claimers spread across N rows rather than queueing behind the oldest.
- The lock is held until commit, so nothing can touch the row between the `SELECT` and the `UPDATE`. No EvalPlanQual subtleties, no re-evaluation, exactly one row.
- `mark_claimed` still checks it updated exactly one row and rolls back otherwise, rather than guessing.
- The return contract is unchanged — `{:ok, job}` / `{:error, :no_jobs}` — because `Repo.rollback(:no_jobs)` produces the same tuple. No caller changed.

## Verification

Measured at the time of the fix, **40 trials of 5 jobs against 5 concurrent claimers:**

| Version | Duplicate claims | Stranded in `started` | Lost rows | Claimed per trial |
|---|---|---|---|---|
| Original single statement | yes (forced interleaving) | 0 | 0 | 3–4 of 5 |
| First fix (`SKIP LOCKED` in subquery) | 0 | **yes** | 0 | — |
| Shipped (select-then-update in a transaction) | **0** | **0** | **0** | 5 of 5 |

The guarantee is the first three columns. Throughput is best-effort: in a simultaneous burst a claimer can come back empty while work exists (the committed test has observed 3–5 of 5). That costs one poll cycle; the row stays `pending` and claimable.

## Testing concurrency honestly

`claim_concurrency_test.exs` (7 tests) **opts out of the Ecto sandbox** — `:auto` mode, `async: false`, explicit cleanup in `on_exit`. The sandbox hands every process in a test the *same* connection, so anything that looks concurrent is silently serialised and proves nothing about two nodes racing.

Where a specific interleaving matters, locks are held from a raw Postgrex connection to force it, rather than hoping the scheduler produces it. The module covers both claim paths:

- **`claim_job/2`** — skips rows another connection holds locked; reports `:no_jobs` without touching a locked row; never steals a row mid-claim; hands a single job to exactly one of several concurrent claimers; and never double-claims or strands rows when claimers spread across several jobs. That last test asserts every row marked `started` is one a caller was told it got — the exact invariant the first fix broke.
- **Cron `claim_tick`** — a tick already advanced by another connection is not fired again, and concurrent scheduler passes enqueue a job exactly once. This turns the multi-node cron claim from something reasoned about into something tested.

## What is still open

The shipped fix prevents rows being stranded by the claim itself. It does not help a job whose worker's node dies mid-run: that row stays `started` indefinitely. An orphan-job reaper needs a lease/heartbeat or a maximum-runtime threshold, and choosing that threshold wrongly re-runs jobs that were merely slow. It is tracked under *Known limitations* in the README.
