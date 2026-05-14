# Design: Queue Auto-Boot + REST API

**Date:** 2026-05-14
**Scope:** Production gaps 1 and 2 — queues must survive application restarts, and the system must expose a JSON REST API for external interaction.

---

## Background

The current implementation has two critical production gaps:

1. **No queue auto-boot** — `QueueManager` processes are transient and started manually. An application restart leaves all queues dead and jobs silently stuck as `pending` forever.
2. **No REST API** — the Phoenix router only serves the default page. There is no way to enqueue jobs, check status, or manage queues externally.

The `scheduled_at` field already exists on `Job`, so one-time future scheduling already works at the data layer — it just needs API exposure. Recurring cron scheduling is deferred to a future design.

---

## Architecture

Two independent additions to the existing system. Neither modifies core queue logic.

### Supervision tree (revised)

```
DistributedTaskQueue.Supervisor (one_for_one)
  ├── Telemetry
  ├── Repo
  ├── DNSCluster
  ├── PubSub
  ├── Finch
  ├── WorkerRegistry
  ├── WorkerSupervisor          ← unchanged
  ├── QueueBootstrapper         ← NEW, placed after WorkerSupervisor
  └── Endpoint
```

### New files

```
lib/
  distributed_task_queue/
    queue_bootstrapper.ex
  distributed_task_queue_web/
    controllers/
      queue_controller.ex
      job_controller.ex
```

---

## Gap 1: QueueBootstrapper

### Module: `DistributedTaskQueue.QueueBootstrapper`

A `GenServer` with `restart: :transient`. Stateless after init — it does one pass at startup then idles.

### Behaviour

On `init/1`:
1. Query all `Queue` records via `DistributedTaskQueue.list_queues/0`.
2. For each queue, call `WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)`.
3. `{:ok, _}` — log info and continue.
4. `{:error, {:already_started, _}}` — silently skip (idempotent).
5. `{:error, reason}` — log warning, continue (does not crash bootstrapper).
6. Return `{:ok, :booted}`.

### Why `:transient`?

If the DB is briefly unavailable at boot (e.g. slow container start), the supervisor restarts the bootstrapper and it retries. Once booted successfully it will not crash under normal operation.

### Implementation sketch

```elixir
defmodule DistributedTaskQueue.QueueBootstrapper do
  use GenServer, restart: :transient
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok) do
    DistributedTaskQueue.list_queues()
    |> Enum.each(fn queue ->
      case DistributedTaskQueue.WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs) do
        {:ok, _}                       -> Logger.info("[QueueBootstrapper] started: #{queue.name}")
        {:error, {:already_started, _}} -> :ok
        {:error, reason}               -> Logger.warning("[QueueBootstrapper] failed #{queue.name}: #{inspect(reason)}")
      end
    end)
    {:ok, :booted}
  end
end
```

---

## Gap 2: REST API

### Pipeline

Add an `:api` pipeline to `router.ex`:

```elixir
pipeline :api do
  plug :accepts, ["json"]
end
```

### Routes

```elixir
scope "/api", DistributedTaskQueueWeb do
  pipe_through :api

  resources "/queues", QueueController, only: [:index, :create]
  post "/queues/:name/start", QueueController, :start
  post "/queues/:name/stop",  QueueController, :stop

  resources "/jobs", JobController, only: [:index, :show, :create, :delete]
end
```

### QueueController

| Action   | Method + Path              | Description |
|----------|---------------------------|-------------|
| `index`  | `GET /api/queues`          | List all queues |
| `create` | `POST /api/queues`         | Create a queue |
| `start`  | `POST /api/queues/:name/start` | Start queue processing |
| `stop`   | `POST /api/queues/:name/stop`  | Stop queue processing |

**`create` request body:**
```json
{
  "name": "emails",
  "description": "Email delivery jobs",
  "max_concurrent_jobs": 5
}
```

### JobController

| Action   | Method + Path       | Description |
|----------|---------------------|-------------|
| `index`  | `GET /api/jobs`     | List jobs; optional `?queue=name&status=pending` filters |
| `show`   | `GET /api/jobs/:id` | Get single job by id |
| `create` | `POST /api/jobs`    | Enqueue a job |
| `delete` | `DELETE /api/jobs/:id` | Soft-delete a job |

**`create` request body:**
```json
{
  "queue_name": "emails",
  "worker_module": "DistributedTaskQueue.EmailWorker",
  "payload": { "to": "user@example.com", "subject": "Hello" },
  "max_attempts": 3,
  "scheduled_at": "2026-05-15T09:00:00Z"
}
```
`max_attempts` and `scheduled_at` are optional. `scheduled_at` enables one-time future scheduling via the existing `claim_job` logic.

### Response shape

All responses use a consistent envelope:

```json
// success (single resource)
{ "data": { "id": 1, "status": "pending", ... } }

// success (list)
{ "data": [ ... ] }

// error
{ "error": "descriptive message" }
```

HTTP status codes follow conventions: `200`, `201`, `404`, `409`, `422`.

---

## Error Handling

| Scenario | HTTP | Body |
|----------|------|------|
| Duplicate queue name | `422` | `{ "error": "name has already been taken" }` |
| Queue not found (start/stop) | `404` | `{ "error": "queue not found" }` |
| Stop queue with pending jobs | `409` | `{ "error": "queue has N pending jobs" }` |
| Start queue already running | `200` | Treated as success (idempotent) |
| Missing required job fields | `422` | `{ "error": "payload can't be blank" }` |
| Delete a running job | `409` | `{ "error": "job is currently running" }` |
| Unknown job or queue id | `404` | `{ "error": "not found" }` |

---

## Out of Scope (this iteration)

- Authentication / API keys
- Recurring cron scheduling (separate future design)
- Exponential backoff (separate improvement)
- LiveView dashboard
- Dead-letter queue
