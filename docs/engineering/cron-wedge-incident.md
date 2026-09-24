# A cron job silently disabled itself

**Status:** fixed · **Code:** `DistributedTaskQueue.CronScheduler` (`lib/distributed_task_queue/cron_scheduler.ex`), `DistributedTaskQueue.ensure_queue_running/1` · **Tests:** `test/distributed_task_queue/cron_scheduler_test.exs`, `describe "missing target queue"`

## Symptom

A cron configured to run every five minutes, `example_job_email`, had stopped running. Nothing was crashing. The logs repeated the same line on every tick:

```
[info] CronScheduler: skipped cron 1 (example_job_email): previous_run_active
SELECT TRUE FROM jobs WHERE cron_job_id = 1 AND status IN ('pending','started') LIMIT 1
```

The cron has `overlap: false`, so it skips while a previous run is still active. The log was accurate — and it was reporting the symptom, not the cause.

## Investigation

Checking the state the log line depended on:

```
cron 1 | queue_name "default" | overlap false | last_run_at 11:25 | next_run_at 11:30
does the cron's queue exist? -> queue_row_exists = false
jobs for cron 1 -> pending: 1 (job 246, worker_id nil, never started)
```

The configuration pointed the cron at `queue_name: "default"`. There was no `default` queue — only `emails` and `testing`.

## Root cause

The chain of events:

1. **11:25** — the cron came due and fired. `add_job("default", …)` **succeeded**: `Job.changeset` validates that `queue_name` is *present*, never that the queue *exists*.
2. `ensure_queue_running("default")` found no queue row, took its `nil -> :ok` branch, started nothing, and said nothing.
3. Job 246 was now unclaimable forever. No `QueueManager` existed for `default`, and `QueueBootstrapper` only starts managers for queue rows that exist at boot.
4. **Every tick after** — `overlap: false` → `no_active_jobs?` sees job 246 `pending` → skip. Permanently.

The cron fired **exactly once** and then disabled itself.

Each component behaved as written. The failure lived in the gaps between them: a validation that checked the wrong property, a helper that returned `:ok` for "I did nothing", and an overlap policy that trusted every `pending` job to eventually be claimed.

## What made it diagnosable — and what didn't

The `:info` skip log, with its reason tag, had been added a couple of weeks earlier as part of a cron observability pass. Without it this would have been a cron that simply never ran, with nothing in the logs at all.

But the reason it reported, `previous_run_active`, was one step removed from the real problem. It pointed at the job, not at why the job could never finish. Good observability names the cause; this named a downstream symptom, and diagnosis still took a manual walk through three tables.

## Fixes

| Change | Why |
|---|---|
| `CronScheduler` skips with reason `:queue_missing` **before** claiming the tick | No unclaimable job is created. `next_run_at` is left unclaimed, so the cron **self-heals** the moment the queue is created — no manual cleanup. |
| That skip logs at `:warning`, not `:info` | The operational skips (`:queue_paused`, `:previous_run_active`) resolve on their own. A missing queue never will. |
| `CronScheduler.missing_queues/0` | Returns enabled crons whose target queue is absent, as `{cron_name, queue_name}`. Called at boot to `Logger.error` each one, with the remedy — `DistributedTaskQueue.add_queue("…")` — in the message. Also usable from a health check. |
| `ensure_queue_running/1` returns `{:error, :queue_not_found}` and warns | Returning `:ok` for a queue that will never drain is what made the original failure invisible. |

The check order in `maybe_fire/1` is deliberate — `queue_missing?` runs before `queue_paused?` and before the overlap check:

```elixir
cond do
  queue_missing?(cron.queue_name) -> skip(cron, :queue_missing)
  queue_paused?(cron.queue_name)  -> skip(cron, :queue_paused)
  not cron.overlap and not no_active_jobs?(cron.id) -> skip(cron, :previous_run_active)
  true ->
    case claim_tick(cron) do
      :ok -> enqueue(cron)
      :already_claimed -> :ok
    end
end
```

Verified against the live development row: boot now reports `cron "example_job_email" -> missing queue "default"`, and `fire_due_crons/0` warns and creates nothing. The committed configuration now points that cron at `emails`.

Tests cover each property: no job is enqueued into a missing queue; the schedule is left unclaimed and the cron fires on its own once the queue is created; the telemetry reason is `:queue_missing` rather than a generic skip; and `missing_queues/0` reports enabled crons but ignores disabled ones.

## The correction this forced

Before this incident, the recommended next piece of work was an **orphan-job reaper**, scoped as *"`started` jobs older than N whose node died."* That design had been recommended twice.

It would not have fixed this. Job 246 was `pending`, `worker_id` nil, `started_at` nil — an age-of-`started` reaper never touches it.

The class of bug is broader than "a worker died mid-run". It is **"a job that can never be claimed"**, which includes anything enqueued into a queue with no running manager. The reaper is still needed, but it is one instance of that class, not a fix for it.

## Still open

- **`add_job/2` accepts any queue name.** The cron path now guards itself; `POST /api/jobs` does not, and can create the same unclaimable job. The fix belongs at the `add_job` choke point rather than at each call site.
- **`no_active_jobs?` ignores `retryable`.** It filters `status IN ('pending', 'started')`, so `overlap: false` does not actually prevent a second run while a previous one is backing off between retries.
