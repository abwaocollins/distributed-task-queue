# Queue Enhancements Design

**Date:** 2026-05-27
**Branch:** feature/queue-enhancements
**Features:** Queue pausing, Dead-letter queue, Telemetry events, ETS queue metadata cache

---

## 1. ETS Queue Metadata Cache (`QueueCache`)

### Purpose
Eliminate the DB round-trip on every `QueueManager` poll cycle by maintaining a shared in-memory mirror of queue metadata.

### Implementation

**New module:** `DistributedTaskQueue.QueueCache`

- Starts as a supervised `GenServer` child in `Application`, after `Repo` and before `QueueBootstrapper`
- `init/1` creates a named public ETS table `:queue_cache` with `read_concurrency: true`
- The GenServer owns the table (survives if callers crash); reads are direct ETS lookups (no GenServer message)

**API:**
```elixir
QueueCache.put(%Queue{})          # insert or replace
QueueCache.get(queue_name)        # returns %Queue{} or nil
QueueCache.delete(queue_name)     # removes entry
QueueCache.all()                  # returns all cached queues
```

**Population:**
- `QueueBootstrapper.do_boot/0` calls `QueueCache.put/1` for each queue after loading from DB
- All context mutations (`add_queue`, `pause_queue`, `resume_queue`) call `QueueCache.put/1` after a successful DB write
- `delete_queue` (if added later) calls `QueueCache.delete/1`

**QueueManager reads:**
`handle_info(:poll, state)` calls `QueueCache.get(state.queue)` to check metadata (initially just `paused`). Falls back to `DistributedTaskQueue.get_queue/1` if cache miss (e.g., cache not yet populated).

---

## 2. Queue Pausing

### Purpose
Allow a queue to be suspended so no new jobs are claimed, without stopping the `QueueManager` process or losing in-flight jobs.

### Migration
```elixir
alter table(:queues) do
  add :paused, :boolean, null: false, default: false
end
```

### Schema changes
- `Queue`: add `field(:paused, :boolean, default: false)`
- `Queue.changeset/2`: include `:paused` in `cast`

### Context functions
```elixir
def pause_queue(queue_name) :: {:ok, %Queue{}} | {:error, term()}
def resume_queue(queue_name) :: {:ok, %Queue{}} | {:error, term()}
```
Both write DB then call `QueueCache.put/1` with the updated struct.

### QueueManager behaviour
At the top of `handle_info(:poll, state)` (both clauses):
```elixir
case QueueCache.get(state.queue) do
  %{paused: true} ->
    schedule_poll()
    {:noreply, state}
  _ ->
    # existing poll logic
end
```
When paused, the manager stays alive and keeps checking. In-flight jobs finish normally.

---

## 3. Dead-Letter Queue (Passive)

### Purpose
Make discarded jobs (exhausted retries) visible as a distinct set for inspection, without losing their origin queue.

### Migration
```elixir
alter table(:jobs) do
  add :dead_letter, :boolean, null: false, default: false
end
create index(:jobs, [:dead_letter])
```

### Schema changes
- `Job`: add `field(:dead_letter, :boolean, default: false)`
- `Job.changeset/2`: include `:dead_letter` in `cast`

### Context changes
In `update_job_status/3`, when `new_status == "discarded"`, merge `%{"dead_letter" => true}` into the extra attrs.

### New context function
```elixir
def list_dead_letter_jobs() :: [%Job{}]
# Returns all jobs where dead_letter == true, ordered by discarded_at desc
```

No new queue row, no QueueManager for DLQ. Purely a query target.

---

## 4. Telemetry Events

### Purpose
Emit structured telemetry events for job lifecycle so LiveDashboard (and future reporters) can track throughput, latency, and failure rates.

### Events

| Event | Trigger | Measurements | Metadata |
|---|---|---|---|
| `[:dtq, :job, :started]` | Before `perform/1` is called | `%{system_time: integer}` | `%{job_id: id, queue_name: string, worker_module: string}` |
| `[:dtq, :job, :completed]` | `perform/1` returns `:ok` | `%{duration: ms}` | `%{job_id: id, queue_name: string, worker_module: string}` |
| `[:dtq, :job, :failed]` | `perform/1` returns `{:error, _}` or raises | `%{duration: ms}` | `%{job_id: id, queue_name: string, worker_module: string, reason: string}` |

`duration` is measured as `System.monotonic_time(:millisecond)` delta from just before `apply/3` to just after.

### Worker changes
`Worker.run_job/1` wraps the `apply` call:
1. Emit `[:dtq, :job, :started]`
2. Record `t0 = System.monotonic_time(:millisecond)`
3. Call `apply(module, :perform, [job.payload])`
4. Compute `duration = System.monotonic_time(:millisecond) - t0`
5. Emit `[:dtq, :job, :completed]` or `[:dtq, :job, :failed]` with duration

### Telemetry module metrics
Add to `DistributedTaskQueueWeb.Telemetry.metrics/0`:
```elixir
summary("dtq.job.completed.duration", unit: {:millisecond, :millisecond}),
summary("dtq.job.failed.duration", unit: {:millisecond, :millisecond}),
counter("dtq.job.started.system_time"),
counter("dtq.job.completed.duration"),
counter("dtq.job.failed.duration"),
```

---

## Files Changed / Created

| Path | Change |
|---|---|
| `lib/distributed_task_queue/queue_cache.ex` | New — ETS cache GenServer |
| `lib/distributed_task_queue/models/queue.ex` | Add `paused` field |
| `lib/distributed_task_queue/models/job.ex` | Add `dead_letter` field |
| `lib/distributed_task_queue/queue_manager.ex` | Check pause flag on poll |
| `lib/distributed_task_queue/worker.ex` | Emit telemetry events |
| `lib/distributed_task_queue.ex` | Add `pause_queue`, `resume_queue`, `list_dead_letter_jobs`; write-through to cache |
| `lib/distributed_task_queue/queue_bootstrapper.ex` | Populate ETS cache on boot |
| `lib/distributed_task_queue/application.ex` | Add `QueueCache` to supervision tree |
| `lib/distributed_task_queue_web/telemetry.ex` | Add DTQ job metrics |
| `priv/repo/migrations/*_add_paused_to_queues.exs` | New migration |
| `priv/repo/migrations/*_add_dead_letter_to_jobs.exs` | New migration |

---

## Open Questions / Non-Goals

- No LiveDashboard page is added in this spec; telemetry metrics make the data available for it
- `delete_queue` is not designed here; cache invalidation for it is left as future work
- DLQ jobs are not automatically retried or requeued in this design
