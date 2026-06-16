# Queue Deletion + Dead-Letter Requeue Design

**Date:** 2026-06-16
**Branch:** feature/queue-delete-and-dlq-requeue
**Features:** Cascade queue deletion (with ETS cache invalidation), dead-letter job requeue (single + bulk)

---

## Background

Two backlog items left as future work by the queue-enhancements milestone (`2026-05-27`):

1. **No `delete_queue/1`.** The system can `stop_queue/1` (terminate a queue's `QueueManager`) but cannot remove a queue. `QueueCache.delete/1` exists but is never called — there is no cache-invalidation path.
2. **Dead-letter queue is inspection-only.** Jobs discarded after exhausting retries are stamped `dead_letter: true` and listed via `list_dead_letter_jobs/0`, but there is no way to put one back into circulation.

Both ship as context functions **and** REST endpoints, consistent with the existing full REST API for queues and jobs.

---

## 1. Cascade Queue Deletion

### Purpose
Permanently remove a queue and all of its job history, tearing down its running process and clearing the ETS cache entry.

### Context function

**New:** `DistributedTaskQueue.delete_queue(queue_name)`

```elixir
def delete_queue(queue_name) :: {:ok, %Queue{}} | {:error, :queue_not_found}
```

Behavior:

1. `get_queue(queue_name)` — `nil` ⇒ `{:error, :queue_not_found}`.
2. **Stop the running `QueueManager` first** via `WorkerSupervisor.stop_queue(queue_name)`, ignoring `{:error, :not_running}`. Done before the DB delete so the manager cannot claim a job that is about to be removed.
3. In a `Repo.transaction`:
   - `Repo.delete_all(from j in Job, where: j.queue_name == ^queue_name)` — hard-delete **all** jobs for the queue (every status: pending, started, retryable, completed, discarded, deleted, dead-lettered).
   - `Repo.delete!(queue)` — hard-delete the queue row.
4. `QueueCache.delete(queue_name)` — invalidate the ETS mirror.
5. ⇒ `{:ok, deleted_queue}`.

> Jobs reference their queue by the `queue_name` **string**, not a DB foreign key, so there is no DB-level cascade — the job deletion is explicit.

> Process termination (step 2) happens outside the transaction and cannot be rolled back. If the DB delete fails after the manager is stopped, the queue row survives and the `QueueBootstrapper` will restart its manager on the next boot. This is an accepted edge case.

### REST endpoint

```
DELETE /api/queues/:name
```

`QueueController.delete/2`:

| Result | HTTP | Body |
|---|---|---|
| `{:ok, queue}` | `200` | `{ "data": { ...queue } }` |
| `{:error, :queue_not_found}` | `404` | `{ "error": "queue not found" }` |

No `409` case — cascade deletes active jobs rather than refusing.

---

## 2. Dead-Letter Requeue

### Purpose
Return a dead-lettered job (or all of them) to the normal pipeline with a fresh set of retry attempts.

### Single-job context function

**New:** `DistributedTaskQueue.requeue_dead_letter_job(job_id)`

```elixir
def requeue_dead_letter_job(job_id) ::
  {:ok, %Job{}} | {:error, :not_found} | {:error, :not_dead_letter}
```

Behavior:

1. `Repo.get(Job, job_id)` — `nil` ⇒ `{:error, :not_found}`.
2. `job.dead_letter != true` ⇒ `{:error, :not_dead_letter}`.
3. Update the job to a claimable state:
   - `status: "pending"`
   - `dead_letter: false`
   - `attempts: 0`
   - `worker_id: nil` (required — `claim_job` only claims rows where `worker_id` is nil)
   - clears: `error_message`, `discarded_at`, `next_retry_at`, `started_at`, `completed_at`
   - keeps: `payload`, `worker_module`, `queue_name`, `max_attempts`, `scheduled_at`
4. **Ensure the queue's `QueueManager` is running** via `ensure_queue_running(job.queue_name)` (a private helper that calls `WorkerSupervisor.start_queue/2`, idempotent — `{:error, {:already_started, _}}` is fine). Without this, a reset job sits `pending` forever if the manager already shut down (managers self-stop when idle). If the queue row no longer exists, skip starting (the job stays `pending`).
5. ⇒ `{:ok, updated_job}`.

### Bulk context function

**New:** `DistributedTaskQueue.requeue_all_dead_letter_jobs()`

```elixir
def requeue_all_dead_letter_jobs() :: {:ok, non_neg_integer()}
```

Iterates `list_dead_letter_jobs/0`, calls `requeue_dead_letter_job/1` for each, and returns `{:ok, count}` where `count` is the number successfully requeued. `ensure_queue_running/1` being idempotent makes the per-job manager start safe to repeat.

### REST endpoints

```
POST /api/jobs/:id/requeue          → JobController.requeue/2
POST /api/jobs/requeue_dead_letter  → JobController.requeue_all/2
```

Both specific routes are declared **before** `resources "/jobs"` so the `:id` segment does not capture `requeue_dead_letter`.

`JobController.requeue/2`:

| Result | HTTP | Body |
|---|---|---|
| `{:ok, job}` | `200` | `{ "data": { ...job } }` |
| `{:error, :not_found}` | `404` | `{ "error": "not found" }` |
| `{:error, :not_dead_letter}` | `422` | `{ "error": "job is not a dead-letter job" }` |

`JobController.requeue_all/2`:

| Result | HTTP | Body |
|---|---|---|
| `{:ok, count}` | `200` | `{ "data": { "requeued": N } }` |

---

## Files Changed / Created

| Path | Change |
|---|---|
| `lib/distributed_task_queue.ex` | Add `delete_queue/1`, `requeue_dead_letter_job/1`, `requeue_all_dead_letter_jobs/0`, private `ensure_queue_running/1` |
| `lib/distributed_task_queue_web/controllers/queue_controller.ex` | Add `delete/2` |
| `lib/distributed_task_queue_web/controllers/job_controller.ex` | Add `requeue/2`, `requeue_all/2` |
| `lib/distributed_task_queue_web/router.ex` | Add `DELETE /api/queues/:name`, `POST /api/jobs/:id/requeue`, `POST /api/jobs/requeue_dead_letter` |
| `test/distributed_task_queue_test.exs` | Add delete_queue + requeue context tests |
| `test/distributed_task_queue_web/controllers/queue_controller_test.exs` | Add delete endpoint tests |
| `test/distributed_task_queue_web/controllers/job_controller_test.exs` | Add requeue endpoint tests |

No migrations. No schema changes (all reset fields are already cast by `Job.changeset/2`).

---

## Testing

**Context (`test/distributed_task_queue_test.exs`):**
- `delete_queue` removes the queue row, deletes all its jobs, removes the `QueueCache` entry, and stops a running manager.
- `delete_queue` returns `{:error, :queue_not_found}` for an unknown queue.
- `requeue_dead_letter_job` flips a dead-lettered job back to `pending`, sets `dead_letter: false`, `attempts: 0`, `worker_id: nil`, and clears `discarded_at`/`error_message`.
- `requeue_dead_letter_job` returns `{:error, :not_found}` for an unknown id and `{:error, :not_dead_letter}` for a non-dead-letter job.
- `requeue_all_dead_letter_jobs` requeues every dead-lettered job and returns the count.

**Controllers:**
- `DELETE /api/queues/:name` → `200` on success, `404` for unknown queue.
- `POST /api/jobs/:id/requeue` → `200` on success, `404` unknown, `422` non-dead-letter.
- `POST /api/jobs/requeue_dead_letter` → `200` with `{requeued: N}`.

---

## Non-Goals

- **Authentication** — the API stays open, consistent with the existing endpoints.
- **Soft delete for queues** — `delete_queue` is a hard, irreversible cascade by design.
- **Per-queue bulk requeue** — `requeue_all_dead_letter_jobs/0` requeues across all queues; a per-queue variant is out of scope.
- **Cron auto-disable on config removal** — tracked separately; not in this spec.
