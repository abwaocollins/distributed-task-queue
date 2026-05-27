# Queue Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add queue pausing, dead-letter job tracking, job lifecycle telemetry, and an ETS metadata cache to eliminate DB round-trips on every poll cycle.

**Architecture:** A new `QueueCache` GenServer owns a named public ETS table mirroring queue metadata; all context mutations write-through to it. `QueueManager` reads the cache on every poll to check `paused` instead of hitting the DB. Discarded jobs get `dead_letter: true` stamped in-place (no new queue/table). Telemetry events are emitted from `Worker.run_job/1` via `:telemetry.execute/3` and surfaced via `telemetry_metrics` for LiveDashboard.

**Tech Stack:** Elixir/OTP, ETS, Ecto/PostgreSQL, `:telemetry`, `telemetry_metrics`

---

## File Map

| File | Change |
|---|---|
| `lib/distributed_task_queue/queue_cache.ex` | **Create** — ETS cache GenServer |
| `lib/distributed_task_queue/application.ex` | Modify — add `QueueCache` before `QueueBootstrapper` |
| `priv/repo/migrations/20260527000001_add_paused_to_queues.exs` | **Create** — `paused boolean` on queues |
| `priv/repo/migrations/20260527000002_add_dead_letter_to_jobs.exs` | **Create** — `dead_letter boolean` on jobs |
| `lib/distributed_task_queue/models/queue.ex` | Modify — add `paused` field |
| `lib/distributed_task_queue/models/job.ex` | Modify — add `dead_letter` field |
| `lib/distributed_task_queue.ex` | Modify — `add_queue` write-through, `pause_queue`, `resume_queue`, `list_dead_letter_jobs`, DLQ flag in `update_job_status` |
| `lib/distributed_task_queue/queue_bootstrapper.ex` | Modify — `QueueCache.put/1` on boot |
| `lib/distributed_task_queue/queue_manager.ex` | Modify — single `handle_info(:poll)` clause + pause check |
| `lib/distributed_task_queue/worker.ex` | Modify — emit telemetry events |
| `lib/distributed_task_queue_web/telemetry.ex` | Modify — add DTQ job metrics |
| `test/distributed_task_queue/queue_cache_test.exs` | **Create** |
| `test/distributed_task_queue/queue_manager_pause_test.exs` | **Create** |
| `test/distributed_task_queue/worker_test.exs` | **Create** |
| `test/distributed_task_queue_test.exs` | Modify — add pause/resume/DLQ tests |
| `test/distributed_task_queue/queue_bootstrapper_test.exs` | Modify — add cache population test |
| `test/support/factory.ex` | Modify — add `paused: false` to `queue_factory` |

---

## Task 1: Create Feature Branch

- [ ] **Step 1: Create and switch to the feature branch**

```bash
git checkout -b feature/queue-enhancements
```

Expected output: `Switched to a new branch 'feature/queue-enhancements'`

---

## Task 2: `QueueCache` Module + Supervision Wiring

**Files:**
- Create: `lib/distributed_task_queue/queue_cache.ex`
- Modify: `lib/distributed_task_queue/application.ex`
- Create: `test/distributed_task_queue/queue_cache_test.exs`

- [ ] **Step 1: Write the failing test**

> Note: `paused` field is not on the `Queue` schema yet (added in Task 3). Tests here use only fields that already exist on the struct.

Create `test/distributed_task_queue/queue_cache_test.exs`:

```elixir
defmodule DistributedTaskQueue.QueueCacheTest do
  use ExUnit.Case, async: false

  alias DistributedTaskQueue.{QueueCache, Queue}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "returns nil for an unknown queue" do
    assert QueueCache.get("does-not-exist") == nil
  end

  test "put and get a queue" do
    queue = %Queue{name: "test-q", max_concurrent_jobs: 5}
    QueueCache.put(queue)
    assert QueueCache.get("test-q") == queue
  end

  test "put overwrites an existing entry" do
    queue = %Queue{name: "overwrite-q", max_concurrent_jobs: 5}
    QueueCache.put(queue)
    QueueCache.put(%{queue | max_concurrent_jobs: 10})
    assert QueueCache.get("overwrite-q").max_concurrent_jobs == 10
  end

  test "delete removes an entry" do
    queue = %Queue{name: "delete-q", max_concurrent_jobs: 5}
    QueueCache.put(queue)
    QueueCache.delete("delete-q")
    assert QueueCache.get("delete-q") == nil
  end

  test "all returns every cached queue" do
    QueueCache.put(%Queue{name: "all-q1", max_concurrent_jobs: 2})
    QueueCache.put(%Queue{name: "all-q2", max_concurrent_jobs: 3})
    names = QueueCache.all() |> Enum.map(& &1.name) |> Enum.sort()
    assert "all-q1" in names
    assert "all-q2" in names
  end
end
```

- [ ] **Step 2: Run the test — expect compile error (module not defined)**

```bash
mix test test/distributed_task_queue/queue_cache_test.exs
```

Expected: compilation error about `DistributedTaskQueue.QueueCache` not existing.

- [ ] **Step 3: Create `QueueCache` module**

Create `lib/distributed_task_queue/queue_cache.ex`:

```elixir
defmodule DistributedTaskQueue.QueueCache do
  use GenServer

  @table :queue_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, :ok}
  end

  def put(%{name: name} = queue) do
    :ets.insert(@table, {name, queue})
    :ok
  end

  def get(queue_name) do
    case :ets.lookup(@table, queue_name) do
      [{^queue_name, queue}] -> queue
      [] -> nil
    end
  end

  def delete(queue_name) do
    :ets.delete(@table, queue_name)
    :ok
  end

  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_name, queue} -> queue end)
  end
end
```

- [ ] **Step 4: Add `QueueCache` to the supervision tree**

In `lib/distributed_task_queue/application.ex`, insert `DistributedTaskQueue.QueueCache` before `DistributedTaskQueue.QueueBootstrapper`:

```elixir
children = [
  DistributedTaskQueueWeb.Telemetry,
  DistributedTaskQueue.Repo,
  {DNSCluster,
   query: Application.get_env(:distributed_task_queue, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: DistributedTaskQueue.PubSub},
  {Finch, name: DistributedTaskQueue.Finch},
  {Registry, keys: :unique, name: DistributedTaskQueue.WorkerRegistry},
  DistributedTaskQueue.WorkerSupervisor,
  DistributedTaskQueue.QueueCache,
  DistributedTaskQueue.QueueBootstrapper,
  DistributedTaskQueue.CronScheduler,
  DistributedTaskQueueWeb.Endpoint
]
```

- [ ] **Step 5: Run tests — expect pass**

```bash
mix test test/distributed_task_queue/queue_cache_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 6: Verify full suite still green**

```bash
mix test
```

Expected: no new failures.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue/queue_cache.ex \
        lib/distributed_task_queue/application.ex \
        test/distributed_task_queue/queue_cache_test.exs
git commit -m "feat: add QueueCache ETS module and wire into supervision tree"
```

---

## Task 3: Queue Pausing — Migration + Schema

**Files:**
- Create: `priv/repo/migrations/20260527000001_add_paused_to_queues.exs`
- Modify: `lib/distributed_task_queue/models/queue.ex`
- Modify: `test/support/factory.ex`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260527000001_add_paused_to_queues.exs`:

```elixir
defmodule DistributedTaskQueue.Repo.Migrations.AddPausedToQueues do
  use Ecto.Migration

  def change do
    alter table(:queues) do
      add :paused, :boolean, null: false, default: false
    end
  end
end
```

- [ ] **Step 2: Run the migration**

```bash
mix ecto.migrate
```

Expected: `== Running 20260527000001 AddPausedToQueues.change/0 forward` then `== Migrated`.

- [ ] **Step 3: Add `paused` field to the `Queue` schema**

Replace the contents of `lib/distributed_task_queue/models/queue.ex`:

```elixir
defmodule DistributedTaskQueue.Queue do
  use Ecto.Schema
  import Ecto.Changeset

  schema "queues" do
    field(:name, :string)
    field(:description, :string)
    field(:max_concurrent_jobs, :integer, default: 5)
    field(:paused, :boolean, default: false)

    timestamps()
  end

  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:name, :description, :max_concurrent_jobs, :paused])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
```

- [ ] **Step 4: Update the factory to include `paused: false`**

In `test/support/factory.ex`, update `queue_factory`:

```elixir
def queue_factory do
  %DistributedTaskQueue.Queue{
    name: sequence(:name, &"queue-#{&1}"),
    description: "Test queue",
    max_concurrent_jobs: 3,
    paused: false
  }
end
```

- [ ] **Step 5: Verify the suite compiles and tests pass**

```bash
mix test
```

Expected: no failures. The new `paused` field has a DB default, so existing tests are unaffected.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260527000001_add_paused_to_queues.exs \
        lib/distributed_task_queue/models/queue.ex \
        test/support/factory.ex
git commit -m "feat: add paused field to Queue schema and migration"
```

---

## Task 4: Queue Pausing — Context Functions + `add_queue` Write-Through

**Files:**
- Modify: `lib/distributed_task_queue.ex`
- Modify: `test/distributed_task_queue_test.exs`

- [ ] **Step 1: Write the failing tests**

Add the following block to `test/distributed_task_queue_test.exs` (after the existing modules, as a new module):

```elixir
defmodule DistributedTaskQueue.QueuePauseTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.QueueCache

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "add_queue writes the queue to QueueCache" do
    {:ok, queue} = DistributedTaskQueue.add_queue(%{"name" => "cache-write-q"})
    assert QueueCache.get("cache-write-q") != nil
    assert QueueCache.get("cache-write-q").name == queue.name
  end

  test "pause_queue sets paused: true in DB and cache" do
    {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => "pausable-q"})
    {:ok, paused} = DistributedTaskQueue.pause_queue("pausable-q")
    assert paused.paused == true
    assert QueueCache.get("pausable-q").paused == true
  end

  test "resume_queue sets paused: false in DB and cache" do
    {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => "resumable-q"})
    {:ok, _} = DistributedTaskQueue.pause_queue("resumable-q")
    {:ok, resumed} = DistributedTaskQueue.resume_queue("resumable-q")
    assert resumed.paused == false
    assert QueueCache.get("resumable-q").paused == false
  end

  test "pause_queue returns error for unknown queue" do
    assert DistributedTaskQueue.pause_queue("ghost-queue") == {:error, :queue_not_found}
  end

  test "resume_queue returns error for unknown queue" do
    assert DistributedTaskQueue.resume_queue("ghost-queue") == {:error, :queue_not_found}
  end
end
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/distributed_task_queue_test.exs
```

Expected: failures — `pause_queue/1` and `resume_queue/1` are undefined, `add_queue` doesn't write to cache yet.

- [ ] **Step 3: Update `add_queue` and add `pause_queue`/`resume_queue` in the context**

In `lib/distributed_task_queue.ex`, add `alias DistributedTaskQueue.QueueCache` at the top of the alias block, then replace the `add_queue` clauses and add the two new functions:

```elixir
alias DistributedTaskQueue.{Job, Queue, CronJob, QueueCache}
```

Replace:

```elixir
def add_queue(attrs) when is_map(attrs) do
  %Queue{}
  |> Queue.changeset(attrs)
  |> Repo.insert()
end

def add_queue(queue_name) when is_binary(queue_name) do
  add_queue(%{"name" => queue_name})
end
```

With:

```elixir
def add_queue(attrs) when is_map(attrs) do
  result =
    %Queue{}
    |> Queue.changeset(attrs)
    |> Repo.insert()

  case result do
    {:ok, queue} -> QueueCache.put(queue)
    _ -> :ok
  end

  result
end

def add_queue(queue_name) when is_binary(queue_name) do
  add_queue(%{"name" => queue_name})
end
```

Then add the two new functions (anywhere in the public API section, e.g. after `stop_queue`):

```elixir
def pause_queue(queue_name) do
  case get_queue(queue_name) do
    nil ->
      {:error, :queue_not_found}

    queue ->
      result = queue |> Queue.changeset(%{paused: true}) |> Repo.update()

      case result do
        {:ok, updated} -> QueueCache.put(updated)
        _ -> :ok
      end

      result
  end
end

def resume_queue(queue_name) do
  case get_queue(queue_name) do
    nil ->
      {:error, :queue_not_found}

    queue ->
      result = queue |> Queue.changeset(%{paused: false}) |> Repo.update()

      case result do
        {:ok, updated} -> QueueCache.put(updated)
        _ -> :ok
      end

      result
  end
end
```

- [ ] **Step 4: Run the tests — expect pass**

```bash
mix test test/distributed_task_queue_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue.ex test/distributed_task_queue_test.exs
git commit -m "feat: add pause_queue/resume_queue and add_queue ETS write-through"
```

---

## Task 5: `QueueManager` — Pause Check + Poll Restructure

**Files:**
- Modify: `lib/distributed_task_queue/queue_manager.ex`
- Create: `test/distributed_task_queue/queue_manager_pause_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/distributed_task_queue/queue_manager_pause_test.exs`:

```elixir
defmodule DistributedTaskQueue.QueueManagerPauseTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{QueueCache, WorkerSupervisor}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "a paused queue does not claim pending jobs" do
    {:ok, queue} = DistributedTaskQueue.add_queue(%{
      "name" => "pause-mgr-#{System.unique_integer([:positive])}",
      "max_concurrent_jobs" => 2
    })
    {:ok, job} = DistributedTaskQueue.add_job(queue.name, %{
      "worker_module" => "DistributedTaskQueue.EmailWorker",
      "payload" => %{}
    })

    # Pause the queue in the cache BEFORE starting the manager
    QueueCache.put(%{queue | paused: true})

    {:ok, manager_pid} = WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)

    # Manually trigger a poll — no waiting for the 5s timer
    send(manager_pid, :poll)
    Process.sleep(100)

    updated_job = DistributedTaskQueue.get_job(job.id)
    assert updated_job.status == "pending"
    assert is_nil(updated_job.worker_id)

    DynamicSupervisor.terminate_child(WorkerSupervisor, manager_pid)
  end
end
```

- [ ] **Step 2: Run to confirm the test currently passes (pause not implemented — job will get claimed)**

```bash
mix test test/distributed_task_queue/queue_manager_pause_test.exs
```

Expected: FAIL — job is claimed despite the paused flag, because `QueueManager` doesn't check the cache yet.

- [ ] **Step 3: Refactor `QueueManager` to a single poll clause with a pause check**

Replace `lib/distributed_task_queue/queue_manager.ex` entirely:

```elixir
defmodule DistributedTaskQueue.QueueManager do
  use GenServer, restart: :transient
  alias DistributedTaskQueue.{Worker, QueueCache}

  @poll_interval 5_000

  def start_link({queue_name, max_concurrency}) do
    GenServer.start_link(__MODULE__,
      %{queue: queue_name, max: max_concurrency, running: 0},
      name: via(queue_name)
    )
  end

  def init(%{max: max} = state) do
    Process.flag(:trap_exit, true)
    schedule_poll()
    {:ok, Map.merge(state, %{free_slots: MapSet.new(1..max), task_slots: %{}})}
  end

  def handle_info(:poll, state) do
    if paused?(state.queue) do
      schedule_poll()
      {:noreply, state}
    else
      do_poll(state)
    end
  end

  # Job finished — return slot and poll immediately
  def handle_info({:job_done, slot, _result}, state) do
    send(self(), :poll)

    {:noreply, %{state |
      running: state.running - 1,
      free_slots: MapSet.put(state.free_slots, slot),
      task_slots: Map.delete(state.task_slots, slot)
    }}
  end

  # Task exited normally after sending {:job_done} — slot already returned
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Task crashed without sending {:job_done} — recover the slot
  def handle_info({:EXIT, pid, _reason}, state) do
    {slot, task_slots} = pop_by_pid(state.task_slots, pid)

    new_state =
      if slot do
        send(self(), :poll)
        %{state |
          running: max(0, state.running - 1),
          free_slots: MapSet.put(state.free_slots, slot),
          task_slots: task_slots
        }
      else
        state
      end

    {:noreply, new_state}
  end

  # Slots available — try to claim a job
  defp do_poll(%{running: running, max: max} = state) when running < max do
    slot = Enum.min(state.free_slots)

    case DistributedTaskQueue.claim_job(state.queue, slot) do
      {:ok, job} ->
        {:ok, pid} = spawn_job(job, slot)

        new_state = %{state |
          running: running + 1,
          free_slots: MapSet.delete(state.free_slots, slot),
          task_slots: Map.put(state.task_slots, slot, pid)
        }

        if new_state.running < max, do: send(self(), :poll)
        {:noreply, new_state}

      {:error, :no_jobs} when running == 0 ->
        case DistributedTaskQueue.next_retryable_delay(state.queue) do
          nil ->
            {:stop, :normal, state}

          delay_ms ->
            Process.send_after(self(), :poll, max(delay_ms, @poll_interval))
            {:noreply, state}
        end

      {:error, :no_jobs} ->
        # Some tasks still running — each {:job_done} will trigger the next :poll
        {:noreply, state}
    end
  end

  # All slots busy — wait for a job to finish
  defp do_poll(state), do: {:noreply, state}

  defp paused?(queue_name) do
    case QueueCache.get(queue_name) do
      %{paused: true} -> true
      _ -> false
    end
  end

  defp spawn_job(job, slot) do
    manager = self()

    Task.start_link(fn ->
      result = Worker.run_job(job)
      send(manager, {:job_done, slot, result})
    end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp pop_by_pid(task_slots, pid) do
    case Enum.find(task_slots, fn {_, p} -> p == pid end) do
      {slot, _} -> {slot, Map.delete(task_slots, slot)}
      nil -> {nil, task_slots}
    end
  end

  defp via(queue_name) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, queue_name}}
  end
end
```

- [ ] **Step 4: Run the pause test — expect pass**

```bash
mix test test/distributed_task_queue/queue_manager_pause_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue/queue_manager.ex \
        test/distributed_task_queue/queue_manager_pause_test.exs
git commit -m "feat: QueueManager checks ETS pause flag before claiming jobs"
```

---

## Task 6: `QueueBootstrapper` — Populate Cache on Boot

**Files:**
- Modify: `lib/distributed_task_queue/queue_bootstrapper.ex`
- Modify: `test/distributed_task_queue/queue_bootstrapper_test.exs`

- [ ] **Step 1: Write the failing test**

Add this test to the `describe` block (or as a standalone test) in `test/distributed_task_queue/queue_bootstrapper_test.exs`. Add `alias DistributedTaskQueue.QueueCache` to the existing aliases at the top:

```elixir
alias DistributedTaskQueue.{WorkerSupervisor, QueueCache}
```

Then add a new test:

```elixir
test "populates QueueCache on boot" do
  queue = insert(:queue,
    name: "cache-boot-#{System.unique_integer([:positive])}",
    max_concurrent_jobs: 2
  )

  run_bootstrapper()

  cached = QueueCache.get(queue.name)
  assert cached != nil
  assert cached.name == queue.name
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/distributed_task_queue/queue_bootstrapper_test.exs
```

Expected: the new test fails — boot doesn't write to QueueCache yet.

- [ ] **Step 3: Update `QueueBootstrapper` to populate cache**

Replace `lib/distributed_task_queue/queue_bootstrapper.ex`:

```elixir
defmodule DistributedTaskQueue.QueueBootstrapper do
  use GenServer, restart: :transient
  require Logger
  alias DistributedTaskQueue.QueueCache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok) do
    {:ok, :not_booted, {:continue, :boot}}
  end

  def handle_continue(:boot, state) do
    do_boot()
    {:stop, :normal, state}
  end

  defp do_boot do
    DistributedTaskQueue.list_queues()
    |> Enum.each(fn queue ->
      QueueCache.put(queue)

      case DistributedTaskQueue.WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs) do
        {:ok, _} ->
          Logger.info("[QueueBootstrapper] started queue: #{queue.name}")

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning("[QueueBootstrapper] failed to start queue #{queue.name}: #{inspect(reason)}")
      end
    end)
  end
end
```

- [ ] **Step 4: Run bootstrapper tests — expect pass**

```bash
mix test test/distributed_task_queue/queue_bootstrapper_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue/queue_bootstrapper.ex \
        test/distributed_task_queue/queue_bootstrapper_test.exs
git commit -m "feat: QueueBootstrapper populates QueueCache on boot"
```

---

## Task 7: Dead-Letter Queue — Migration + Job Schema

**Files:**
- Create: `priv/repo/migrations/20260527000002_add_dead_letter_to_jobs.exs`
- Modify: `lib/distributed_task_queue/models/job.ex`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260527000002_add_dead_letter_to_jobs.exs`:

```elixir
defmodule DistributedTaskQueue.Repo.Migrations.AddDeadLetterToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :dead_letter, :boolean, null: false, default: false
    end

    create index(:jobs, [:dead_letter])
  end
end
```

- [ ] **Step 2: Run the migration**

```bash
mix ecto.migrate
```

Expected: `== Running 20260527000002 AddDeadLetterToJobs.change/0 forward` then `== Migrated`.

- [ ] **Step 3: Add `dead_letter` to the `Job` schema**

Replace `lib/distributed_task_queue/models/job.ex`:

```elixir
defmodule DistributedTaskQueue.Job do
  use Ecto.Schema
  import Ecto.Changeset

  schema "jobs" do
    field(:payload, :map)
    field(:worker_module, :string)
    field(:worker_id, :integer)
    field(:queue_name, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:max_attempts, :integer, default: 3)
    field(:error_message, :string)
    field(:scheduled_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:next_retry_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:discarded_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:attempted_by, :string)
    field(:dead_letter, :boolean, default: false)
    belongs_to(:cron_job, DistributedTaskQueue.CronJob)

    timestamps()
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :payload,
      :worker_module,
      :worker_id,
      :queue_name,
      :status,
      :attempts,
      :max_attempts,
      :error_message,
      :scheduled_at,
      :started_at,
      :next_retry_at,
      :completed_at,
      :discarded_at,
      :deleted_at,
      :attempted_by,
      :dead_letter,
      :cron_job_id
    ])
    |> validate_required([:payload, :queue_name, :worker_module])
  end
end
```

- [ ] **Step 4: Verify suite still passes**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260527000002_add_dead_letter_to_jobs.exs \
        lib/distributed_task_queue/models/job.ex
git commit -m "feat: add dead_letter field to Job schema and migration"
```

---

## Task 8: Dead-Letter Queue — Context Changes

**Files:**
- Modify: `lib/distributed_task_queue.ex`
- Modify: `test/distributed_task_queue_test.exs`

- [ ] **Step 1: Write the failing tests**

Add a new module to `test/distributed_task_queue_test.exs`:

```elixir
defmodule DistributedTaskQueue.DeadLetterTest do
  use DistributedTaskQueue.DataCase, async: true

  test "discarding a job sets dead_letter: true" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, status: "pending", max_attempts: 1)

    {:ok, discarded} = DistributedTaskQueue.update_job_status(job.id, "discarded", "exhausted")

    assert discarded.dead_letter == true
    assert discarded.status == "discarded"
    assert discarded.discarded_at != nil
  end

  test "non-discarded status transitions do not set dead_letter" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, status: "pending")

    {:ok, completed} = DistributedTaskQueue.update_job_status(job.id, "completed")

    assert completed.dead_letter == false
  end

  test "list_dead_letter_jobs returns only dead-lettered jobs" do
    queue = insert(:queue)
    job_a = insert(:job, queue_name: queue.name, max_attempts: 1)
    job_b = insert(:job, queue_name: queue.name, max_attempts: 1)
    _job_c = insert(:job, queue_name: queue.name, max_attempts: 3)

    DistributedTaskQueue.update_job_status(job_a.id, "discarded", "failed")
    DistributedTaskQueue.update_job_status(job_b.id, "discarded", "failed")

    dead = DistributedTaskQueue.list_dead_letter_jobs()
    ids = Enum.map(dead, & &1.id)

    assert job_a.id in ids
    assert job_b.id in ids
  end
end
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/distributed_task_queue_test.exs
```

Expected: failures — `list_dead_letter_jobs/0` undefined, `dead_letter` not being set on discard.

- [ ] **Step 3: Update `update_job_status` and add `list_dead_letter_jobs` in the context**

In `lib/distributed_task_queue.ex`, find the `"discarded"` branch in `update_job_status/3` and add `"dead_letter" => true`:

```elixir
"discarded" ->
  %{
    "discarded_at" => DateTime.utc_now(),
    "error_message" => error_message,
    "dead_letter" => true
  }
```

Then add `list_dead_letter_jobs/0` to the public API (e.g. after `list_pending_jobs`):

```elixir
def list_dead_letter_jobs do
  Repo.all(from j in Job, where: j.dead_letter == true, order_by: [desc: j.discarded_at])
end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
mix test test/distributed_task_queue_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue.ex test/distributed_task_queue_test.exs
git commit -m "feat: stamp dead_letter on discard, add list_dead_letter_jobs/0"
```

---

## Task 9: `Worker` — Telemetry Events

**Files:**
- Modify: `lib/distributed_task_queue/worker.ex`
- Create: `test/distributed_task_queue/worker_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/distributed_task_queue/worker_test.exs`:

```elixir
defmodule DistributedTaskQueue.WorkerTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.Worker

  # Inline test worker modules
  defmodule SuccessWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: :ok
  end

  defmodule FailingWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: {:error, "intentional failure"}
  end

  defmodule RaisingWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: raise("boom")
  end

  defp attach_handler(id, events) do
    test_pid = self()

    :telemetry.attach_many(id, events, fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "emits :started and :completed for a successful job" do
    queue = insert(:queue)
    job = insert(:job,
      queue_name: queue.name,
      worker_module: "DistributedTaskQueue.WorkerTest.SuccessWorker"
    )

    attach_handler("test-success-#{job.id}", [[:dtq, :job, :started], [:dtq, :job, :completed]])

    Worker.run_job(job)

    assert_receive {:telemetry, [:dtq, :job, :started], %{system_time: st},
                    %{job_id: ^job.id, queue_name: _, worker_module: _}}
    assert is_integer(st)

    assert_receive {:telemetry, [:dtq, :job, :completed], %{duration: d},
                    %{job_id: ^job.id, queue_name: _, worker_module: _}}
    assert is_integer(d) and d >= 0
  end

  test "emits :started and :failed for a job returning {:error, reason}" do
    queue = insert(:queue)
    job = insert(:job,
      queue_name: queue.name,
      worker_module: "DistributedTaskQueue.WorkerTest.FailingWorker",
      max_attempts: 3
    )

    attach_handler("test-fail-#{job.id}", [[:dtq, :job, :started], [:dtq, :job, :failed]])

    Worker.run_job(job)

    assert_receive {:telemetry, [:dtq, :job, :started], _, _}

    assert_receive {:telemetry, [:dtq, :job, :failed], %{duration: d},
                    %{job_id: ^job.id, reason: reason}}
    assert is_integer(d) and d >= 0
    assert reason == "intentional failure"
  end

  test "emits :failed with exception message when worker raises" do
    queue = insert(:queue)
    job = insert(:job,
      queue_name: queue.name,
      worker_module: "DistributedTaskQueue.WorkerTest.RaisingWorker",
      max_attempts: 3
    )

    attach_handler("test-raise-#{job.id}", [[:dtq, :job, :failed]])

    Worker.run_job(job)

    assert_receive {:telemetry, [:dtq, :job, :failed], %{duration: _},
                    %{job_id: ^job.id, reason: "boom"}}
  end
end
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/distributed_task_queue/worker_test.exs
```

Expected: failures — no telemetry events are emitted yet.

- [ ] **Step 3: Update `Worker.run_job/1` to emit telemetry events**

Replace `lib/distributed_task_queue/worker.ex`:

```elixir
defmodule DistributedTaskQueue.Worker do
  @callback perform(payload :: map()) :: :ok | {:error, reason :: term()}

  def run_job(job) do
    metadata = %{
      job_id: job.id,
      queue_name: job.queue_name,
      worker_module: job.worker_module
    }

    :telemetry.execute([:dtq, :job, :started], %{system_time: System.system_time()}, metadata)
    t0 = System.monotonic_time(:millisecond)

    try do
      module = job.worker_module |> String.split(".") |> Module.concat()

      case apply(module, :perform, [job.payload]) do
        :ok ->
          duration = System.monotonic_time(:millisecond) - t0
          :telemetry.execute([:dtq, :job, :completed], %{duration: duration}, metadata)
          DistributedTaskQueue.update_job_status(job.id, "completed")

        {:error, reason} ->
          reason_str = if is_binary(reason), do: reason, else: inspect(reason)
          duration = System.monotonic_time(:millisecond) - t0
          :telemetry.execute([:dtq, :job, :failed], %{duration: duration},
            Map.put(metadata, :reason, reason_str))
          handle_failure(job, reason_str)
      end
    rescue
      e ->
        reason_str = Exception.message(e)
        duration = System.monotonic_time(:millisecond) - t0
        :telemetry.execute([:dtq, :job, :failed], %{duration: duration},
          Map.put(metadata, :reason, reason_str))
        handle_failure(job, reason_str)
    end
  end

  defp handle_failure(job, reason_str) do
    new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
    DistributedTaskQueue.update_job_status(job.id, new_status, reason_str)
  end
end
```

- [ ] **Step 4: Run the worker tests — expect pass**

```bash
mix test test/distributed_task_queue/worker_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue/worker.ex \
        test/distributed_task_queue/worker_test.exs
git commit -m "feat: emit :job_started, :job_completed, :job_failed telemetry events"
```

---

## Task 10: Telemetry Module — Add DTQ Metrics

**Files:**
- Modify: `lib/distributed_task_queue_web/telemetry.ex`

There are no behavioural tests for metric definitions (they're declarative), so this task skips the red step.

- [ ] **Step 1: Add DTQ metrics to `metrics/0`**

In `lib/distributed_task_queue_web/telemetry.ex`, add the following entries to the list returned by `metrics/0` (after the existing VM metrics):

```elixir
# DTQ Job Metrics
counter("dtq.job.started.system_time",
  tags: [:queue_name, :worker_module]
),
counter("dtq.job.completed.duration",
  tags: [:queue_name, :worker_module]
),
counter("dtq.job.failed.duration",
  tags: [:queue_name, :worker_module]
),
summary("dtq.job.completed.duration",
  tags: [:queue_name, :worker_module],
  unit: {:millisecond, :millisecond}
),
summary("dtq.job.failed.duration",
  tags: [:queue_name, :worker_module],
  unit: {:millisecond, :millisecond}
)
```

- [ ] **Step 2: Verify the app compiles**

```bash
mix compile --force 2>&1 | tail -5
```

Expected: no errors (warnings about missing tag extractors are fine — LiveDashboard handles them).

- [ ] **Step 3: Run full suite**

```bash
mix test
```

Expected: no failures.

- [ ] **Step 4: Commit**

```bash
git add lib/distributed_task_queue_web/telemetry.ex
git commit -m "feat: register DTQ job telemetry metrics for LiveDashboard"
```

---

## Done — All Tasks Complete

Verify final state:

```bash
mix test
```

Expected: full suite green.

Summary of what was built:

- **`QueueCache`** — public ETS table with write-through on all queue mutations; survives QueueManager restarts; eliminates DB round-trips on every poll
- **Queue pausing** — `pause_queue/1` / `resume_queue/1` persist to DB + ETS; `QueueManager` skips job claiming while paused, stays alive, checks again on next poll
- **Dead-letter tracking** — jobs discarded after exhausting retries get `dead_letter: true`; origin queue preserved; queryable via `list_dead_letter_jobs/0`
- **Telemetry** — `[:dtq, :job, :started/completed/failed]` events with `duration`, `job_id`, `queue_name`, `worker_module` metadata; metrics registered with `telemetry_metrics` for LiveDashboard
