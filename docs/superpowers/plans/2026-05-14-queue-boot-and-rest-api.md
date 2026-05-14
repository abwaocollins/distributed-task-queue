# Queue Auto-Boot + REST API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make queues survive application restarts and expose a JSON REST API for managing queues and jobs.

**Architecture:** A `QueueBootstrapper` GenServer starts after `WorkerSupervisor` in the supervision tree and auto-starts all DB queues on boot. A JSON API adds `QueueController` and `JobController` under `/api`, wired into the existing `:api` pipeline. No changes to core queue logic.

**Tech Stack:** Elixir/OTP, Phoenix 1.7, Ecto, PostgreSQL, ExUnit + SQL Sandbox, ExMachina (already in deps)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/distributed_task_queue/queue_bootstrapper.ex` | **Create** | GenServer that starts all DB queues on app boot |
| `lib/distributed_task_queue/application.ex` | **Modify** | Add `QueueBootstrapper` to supervision tree |
| `lib/distributed_task_queue_web/router.ex` | **Modify** | Uncomment `:api` scope, add queue + job routes |
| `lib/distributed_task_queue_web/controllers/queue_controller.ex` | **Create** | `index`, `create`, `start`, `stop` actions |
| `lib/distributed_task_queue_web/controllers/job_controller.ex` | **Create** | `index`, `show`, `create`, `delete` actions |
| `test/support/data_case.ex` | **Create** | DB-sandbox test case (mirrors ConnCase for unit tests) |
| `test/support/factory.ex` | **Create** | ExMachina factories for Queue and Job |
| `test/distributed_task_queue/queue_bootstrapper_test.exs` | **Create** | Unit tests for bootstrapper |
| `test/distributed_task_queue_web/controllers/queue_controller_test.exs` | **Create** | Integration tests for queue API |
| `test/distributed_task_queue_web/controllers/job_controller_test.exs` | **Create** | Integration tests for job API |

---

## Task 1: Test infrastructure — DataCase + ExMachina factories

Before any feature work, wire up the test helpers that all subsequent tests depend on.

**Files:**
- Create: `test/support/data_case.ex`
- Create: `test/support/factory.ex`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Create DataCase**

Create `test/support/data_case.ex`:

```elixir
defmodule DistributedTaskQueue.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias DistributedTaskQueue.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DistributedTaskQueue.DataCase
    end
  end

  setup tags do
    DistributedTaskQueue.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DistributedTaskQueue.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
```

- [ ] **Step 2: Create ExMachina factory**

Create `test/support/factory.ex`:

```elixir
defmodule DistributedTaskQueue.Factory do
  use ExMachina.Ecto, repo: DistributedTaskQueue.Repo

  def queue_factory do
    %DistributedTaskQueue.Queue{
      name: sequence(:name, &"queue-#{&1}"),
      description: "Test queue",
      max_concurrent_jobs: 3
    }
  end

  def job_factory do
    %DistributedTaskQueue.Job{
      queue_name: sequence(:queue_name, &"queue-#{&1}"),
      worker_module: "DistributedTaskQueue.EmailWorker",
      payload: %{"to" => "test@example.com"},
      status: "pending",
      max_attempts: 3
    }
  end
end
```

- [ ] **Step 3: Switch test_helper to manual sandbox mode**

Update `test/test_helper.exs` — the current `:auto` mode is incompatible with `Sandbox.start_owner!`. Switch to `:manual`:

```elixir
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(DistributedTaskQueue.Repo, :manual)
```

- [ ] **Step 4: Verify no existing tests break**

```bash
mix test
```

Expected: all existing tests pass (there are only scaffold tests). If the page_controller_test fails with a sandbox error, add `use DistributedTaskQueue.DataCase` or the sandbox setup to `ConnCase` — see Step 5.

- [ ] **Step 5: Add sandbox setup to ConnCase**

`test/support/conn_case.ex` needs the same sandbox setup so controller tests work. Update the `setup` block:

```elixir
setup tags do
  DistributedTaskQueue.DataCase.setup_sandbox(tags)
  {:ok, conn: Phoenix.ConnTest.build_conn()}
end
```

Also add the import at the top of the `using` block:

```elixir
using do
  quote do
    @endpoint DistributedTaskQueueWeb.Endpoint
    use DistributedTaskQueueWeb, :verified_routes
    import Plug.Conn
    import Phoenix.ConnTest
    import DistributedTaskQueueWeb.ConnCase
    import DistributedTaskQueue.Factory
  end
end
```

- [ ] **Step 6: Run tests again**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add test/support/data_case.ex test/support/factory.ex test/test_helper.exs test/support/conn_case.ex
git commit -m "test: add DataCase, ExMachina factory, fix sandbox mode"
```

---

## Task 2: QueueBootstrapper GenServer

**Files:**
- Create: `lib/distributed_task_queue/queue_bootstrapper.ex`
- Modify: `lib/distributed_task_queue/application.ex`
- Create: `test/distributed_task_queue/queue_bootstrapper_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/distributed_task_queue/queue_bootstrapper_test.exs`:

```elixir
defmodule DistributedTaskQueue.QueueBootstrapperTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{QueueBootstrapper, WorkerSupervisor, Factory}

  setup do
    # Stop any queue managers left over from other tests
    on_exit(fn ->
      DistributedTaskQueue.list_queues()
      |> Enum.each(fn q ->
        WorkerSupervisor.stop_queue(q.name)
      end)
    end)
    :ok
  end

  test "starts a QueueManager for every Queue in the database" do
    Factory.insert(:queue, name: "boot-test-1", max_concurrent_jobs: 2)
    Factory.insert(:queue, name: "boot-test-2", max_concurrent_jobs: 1)

    # Restart the bootstrapper to trigger a fresh boot scan
    GenServer.stop(QueueBootstrapper, :normal)
    # Give the supervisor time to restart it
    Process.sleep(200)

    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, "boot-test-1")
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, "boot-test-2")
  end

  test "does not crash when a queue is already running" do
    queue = Factory.insert(:queue, name: "already-running", max_concurrent_jobs: 1)
    WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)

    # Should not raise or crash the bootstrapper
    assert {:ok, :booted} = QueueBootstrapper.boot()
  end

  test "does not crash when DB has no queues" do
    assert {:ok, :booted} = QueueBootstrapper.boot()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/distributed_task_queue/queue_bootstrapper_test.exs
```

Expected: compile error — `QueueBootstrapper` does not exist yet.

- [ ] **Step 3: Implement QueueBootstrapper**

Create `lib/distributed_task_queue/queue_bootstrapper.ex`:

```elixir
defmodule DistributedTaskQueue.QueueBootstrapper do
  use GenServer, restart: :transient
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # Public helper used in tests and for manual re-triggering
  def boot do
    DistributedTaskQueue.list_queues()
    |> Enum.each(fn queue ->
      case DistributedTaskQueue.WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs) do
        {:ok, _} ->
          Logger.info("[QueueBootstrapper] started queue: #{queue.name}")
        {:error, {:already_started, _}} ->
          :ok
        {:error, reason} ->
          Logger.warning("[QueueBootstrapper] failed to start queue #{queue.name}: #{inspect(reason)}")
      end
    end)
    {:ok, :booted}
  end

  def init(:ok) do
    result = boot()
    result
  end
end
```

- [ ] **Step 4: Add QueueBootstrapper to the supervision tree**

Update `lib/distributed_task_queue/application.ex`. Add `DistributedTaskQueue.QueueBootstrapper` after `DistributedTaskQueue.WorkerSupervisor`:

```elixir
children = [
  DistributedTaskQueueWeb.Telemetry,
  DistributedTaskQueue.Repo,
  {DNSCluster, query: Application.get_env(:distributed_task_queue, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: DistributedTaskQueue.PubSub},
  {Finch, name: DistributedTaskQueue.Finch},
  {Registry, keys: :unique, name: DistributedTaskQueue.WorkerRegistry},
  DistributedTaskQueue.WorkerSupervisor,
  DistributedTaskQueue.QueueBootstrapper,
  DistributedTaskQueueWeb.Endpoint
]
```

- [ ] **Step 5: Run tests**

```bash
mix test test/distributed_task_queue/queue_bootstrapper_test.exs
```

Expected: all 3 tests pass.

- [ ] **Step 6: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue/queue_bootstrapper.ex lib/distributed_task_queue/application.ex test/distributed_task_queue/queue_bootstrapper_test.exs
git commit -m "feat(boot): add QueueBootstrapper to auto-start queues on application boot"
```

---

## Task 3: Router — wire up the API scope

No logic yet — just routing. Tests will catch 404s becoming real responses.

**Files:**
- Modify: `lib/distributed_task_queue_web/router.ex`

- [ ] **Step 1: Uncomment and populate the `/api` scope**

Replace the commented-out scope block in `lib/distributed_task_queue_web/router.ex`:

```elixir
scope "/api", DistributedTaskQueueWeb do
  pipe_through :api

  resources "/queues", QueueController, only: [:index, :create]
  post "/queues/:name/start", QueueController, :start
  post "/queues/:name/stop",  QueueController, :stop

  resources "/jobs", JobController, only: [:index, :show, :create, :delete]
end
```

The `:api` pipeline already exists in the router (plug `:accepts, ["json"]`) — no changes needed there.

- [ ] **Step 2: Verify routes compile**

```bash
mix phx.routes
```

Expected: output includes lines for `/api/queues`, `/api/queues/:name/start`, `/api/queues/:name/stop`, `/api/jobs`, `/api/jobs/:id`.

The compile will fail if `QueueController` or `JobController` don't exist yet — that's expected at this step. Proceed to Task 4.

- [ ] **Step 3: Commit**

```bash
git add lib/distributed_task_queue_web/router.ex
git commit -m "feat(api): add /api route scope for queues and jobs"
```

---

## Task 4: QueueController

**Files:**
- Create: `lib/distributed_task_queue_web/controllers/queue_controller.ex`
- Create: `test/distributed_task_queue_web/controllers/queue_controller_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/distributed_task_queue_web/controllers/queue_controller_test.exs`:

```elixir
defmodule DistributedTaskQueueWeb.QueueControllerTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  describe "GET /api/queues" do
    test "returns empty list when no queues exist", %{conn: conn} do
      conn = get(conn, ~p"/api/queues")
      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns all queues", %{conn: conn} do
      insert(:queue, name: "emails")
      insert(:queue, name: "reports")

      conn = get(conn, ~p"/api/queues")
      response = json_response(conn, 200)
      names = Enum.map(response["data"], & &1["name"])
      assert "emails" in names
      assert "reports" in names
    end
  end

  describe "POST /api/queues" do
    test "creates a queue with valid params", %{conn: conn} do
      params = %{name: "sms", description: "SMS jobs", max_concurrent_jobs: 10}
      conn = post(conn, ~p"/api/queues", params)
      assert %{"data" => %{"name" => "sms", "max_concurrent_jobs" => 10}} = json_response(conn, 201)
    end

    test "returns 422 when name is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/queues", %{description: "no name"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 422 when name is duplicate", %{conn: conn} do
      insert(:queue, name: "dup")
      conn = post(conn, ~p"/api/queues", %{name: "dup"})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "POST /api/queues/:name/start" do
    test "starts a queue that exists in DB", %{conn: conn} do
      insert(:queue, name: "startable", max_concurrent_jobs: 2)
      conn = post(conn, ~p"/api/queues/startable/start")
      assert %{"data" => %{"status" => "started"}} = json_response(conn, 200)
    end

    test "is idempotent — starting an already-running queue returns 200", %{conn: conn} do
      insert(:queue, name: "already", max_concurrent_jobs: 1)
      post(conn, ~p"/api/queues/already/start")
      conn = post(conn, ~p"/api/queues/already/start")
      assert %{"data" => %{"status" => "started"}} = json_response(conn, 200)
    end

    test "returns 404 for unknown queue", %{conn: conn} do
      conn = post(conn, ~p"/api/queues/ghost/start")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end

  describe "POST /api/queues/:name/stop" do
    test "stops a running queue with no pending jobs", %{conn: conn} do
      insert(:queue, name: "stoppable", max_concurrent_jobs: 1)
      post(conn, ~p"/api/queues/stoppable/start")
      conn = post(conn, ~p"/api/queues/stoppable/stop")
      assert %{"data" => %{"status" => "stopped"}} = json_response(conn, 200)
    end

    test "returns 409 when queue has pending jobs", %{conn: conn} do
      insert(:queue, name: "busy", max_concurrent_jobs: 1)
      insert(:job, queue_name: "busy", status: "pending")
      post(conn, ~p"/api/queues/busy/start")
      conn = post(conn, ~p"/api/queues/busy/stop")
      assert %{"error" => _} = json_response(conn, 409)
    end

    test "returns 404 for unknown queue", %{conn: conn} do
      conn = post(conn, ~p"/api/queues/ghost/stop")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/distributed_task_queue_web/controllers/queue_controller_test.exs
```

Expected: compile error — `QueueController` does not exist yet.

- [ ] **Step 3: Implement QueueController**

Create `lib/distributed_task_queue_web/controllers/queue_controller.ex`:

```elixir
defmodule DistributedTaskQueueWeb.QueueController do
  use DistributedTaskQueueWeb, :controller

  def index(conn, _params) do
    queues = DistributedTaskQueue.list_queues()
    json(conn, %{data: Enum.map(queues, &queue_json/1)})
  end

  def create(conn, params) do
    case DistributedTaskQueue.add_queue(params["name"] || params[:name]) do
      {:ok, queue} ->
        conn
        |> put_status(:created)
        |> json(%{data: queue_json(queue)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  def start(conn, %{"name" => name}) do
    case DistributedTaskQueue.start_queue(name) do
      {:ok, _} ->
        json(conn, %{data: %{name: name, status: "started"}})

      {:error, {:already_started, _}} ->
        json(conn, %{data: %{name: name, status: "started"}})

      {:error, :queue_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "queue not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"name" => name}) do
    case DistributedTaskQueue.stop_queue(name) do
      :ok ->
        json(conn, %{data: %{name: name, status: "stopped"}})

      {:error, {:pending_jobs, count}} ->
        conn |> put_status(:conflict) |> json(%{error: "queue has #{count} pending jobs"})

      {:error, :not_running} ->
        conn |> put_status(:not_found) |> json(%{error: "queue not found or not running"})

      {:error, :queue_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "queue not found"})
    end
  end

  defp queue_json(queue) do
    %{
      id: queue.id,
      name: queue.name,
      description: queue.description,
      max_concurrent_jobs: queue.max_concurrent_jobs,
      inserted_at: queue.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
```

- [ ] **Step 4: Fix `add_queue` to accept a map with description and max_concurrent_jobs**

The current `add_queue/1` in `lib/distributed_task_queue.ex` only takes `queue_name`. Update it to accept a map so the API can set `description` and `max_concurrent_jobs`:

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

Update the `create` action in `QueueController` to pass the full params map:

```elixir
def create(conn, params) do
  case DistributedTaskQueue.add_queue(params) do
    {:ok, queue} ->
      conn
      |> put_status(:created)
      |> json(%{data: queue_json(queue)})

    {:error, changeset} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: format_errors(changeset)})
  end
end
```

- [ ] **Step 5: Run queue controller tests**

```bash
mix test test/distributed_task_queue_web/controllers/queue_controller_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue_web/controllers/queue_controller.ex lib/distributed_task_queue.ex test/distributed_task_queue_web/controllers/queue_controller_test.exs
git commit -m "feat(api): add QueueController with index, create, start, stop actions"
```

---

## Task 5: JobController

**Files:**
- Create: `lib/distributed_task_queue_web/controllers/job_controller.ex`
- Create: `test/distributed_task_queue_web/controllers/job_controller_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/distributed_task_queue_web/controllers/job_controller_test.exs`:

```elixir
defmodule DistributedTaskQueueWeb.JobControllerTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  describe "GET /api/jobs" do
    test "returns all jobs when no filters", %{conn: conn} do
      insert(:job, queue_name: "q1", status: "pending")
      insert(:job, queue_name: "q2", status: "completed")
      conn = get(conn, ~p"/api/jobs")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) >= 2
    end

    test "filters by queue name", %{conn: conn} do
      insert(:job, queue_name: "target")
      insert(:job, queue_name: "other")
      conn = get(conn, ~p"/api/jobs?queue=target")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert Enum.all?(jobs, fn j -> j["queue_name"] == "target" end)
    end

    test "filters by status", %{conn: conn} do
      insert(:job, status: "pending")
      insert(:job, status: "completed")
      conn = get(conn, ~p"/api/jobs?status=pending")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert Enum.all?(jobs, fn j -> j["status"] == "pending" end)
    end

    test "filters by both queue and status", %{conn: conn} do
      insert(:job, queue_name: "q", status: "pending")
      insert(:job, queue_name: "q", status: "completed")
      insert(:job, queue_name: "other", status: "pending")
      conn = get(conn, ~p"/api/jobs?queue=q&status=pending")
      assert %{"data" => [job]} = json_response(conn, 200)
      assert job["queue_name"] == "q"
      assert job["status"] == "pending"
    end
  end

  describe "GET /api/jobs/:id" do
    test "returns job when found", %{conn: conn} do
      job = insert(:job)
      conn = get(conn, ~p"/api/jobs/#{job.id}")
      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == job.id
    end

    test "returns 404 when not found", %{conn: conn} do
      conn = get(conn, ~p"/api/jobs/0")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end

  describe "POST /api/jobs" do
    test "enqueues a job with required fields", %{conn: conn} do
      params = %{
        queue_name: "emails",
        worker_module: "DistributedTaskQueue.EmailWorker",
        payload: %{to: "x@example.com"}
      }
      conn = post(conn, ~p"/api/jobs", params)
      assert %{"data" => %{"status" => "pending", "queue_name" => "emails"}} = json_response(conn, 201)
    end

    test "enqueues with optional max_attempts", %{conn: conn} do
      params = %{
        queue_name: "emails",
        worker_module: "DistributedTaskQueue.EmailWorker",
        payload: %{to: "x@example.com"},
        max_attempts: 5
      }
      conn = post(conn, ~p"/api/jobs", params)
      assert %{"data" => %{"max_attempts" => 5}} = json_response(conn, 201)
    end

    test "enqueues with optional scheduled_at", %{conn: conn} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      params = %{
        queue_name: "emails",
        worker_module: "DistributedTaskQueue.EmailWorker",
        payload: %{to: "x@example.com"},
        scheduled_at: future
      }
      conn = post(conn, ~p"/api/jobs", params)
      assert %{"data" => %{"scheduled_at" => sat}} = json_response(conn, 201)
      assert sat != nil
    end

    test "returns 422 when payload is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/jobs", %{queue_name: "emails"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 422 when queue_name is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/jobs", %{payload: %{}, worker_module: "Foo"})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/jobs/:id" do
    test "soft-deletes a pending job", %{conn: conn} do
      job = insert(:job, status: "pending")
      conn = delete(conn, ~p"/api/jobs/#{job.id}")
      assert %{"data" => %{"status" => "deleted"}} = json_response(conn, 200)
    end

    test "returns 409 when job is currently running", %{conn: conn} do
      job = insert(:job, status: "started")
      conn = delete(conn, ~p"/api/jobs/#{job.id}")
      assert %{"error" => _} = json_response(conn, 409)
    end

    test "returns 404 when job not found", %{conn: conn} do
      conn = delete(conn, ~p"/api/jobs/0")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/distributed_task_queue_web/controllers/job_controller_test.exs
```

Expected: compile error — `JobController` does not exist yet.

- [ ] **Step 3: Add `list_jobs_filtered/1` to the context module**

The current `lib/distributed_task_queue.ex` has separate `list_jobs/0`, `list_pending_jobs/0`, and `list_jobs_in_queue/1`. The API needs combined filtering. Add:

```elixir
def list_jobs_filtered(filters \\ %{}) do
  query = from j in Job, where: is_nil(j.deleted_at)

  query =
    case Map.get(filters, "queue") || Map.get(filters, :queue) do
      nil -> query
      queue -> from j in query, where: j.queue_name == ^queue
    end

  query =
    case Map.get(filters, "status") || Map.get(filters, :status) do
      nil -> query
      status -> from j in query, where: j.status == ^status
    end

  Repo.all(from j in query, order_by: [asc: j.inserted_at])
end
```

- [ ] **Step 4: Add `delete_job` guard for running jobs**

The current `delete_job/1` in `lib/distributed_task_queue.ex` soft-deletes any job regardless of status. Add a guard so it returns `{:error, :job_running}` for `started` jobs:

```elixir
def delete_job(job_id) do
  job = Repo.get(Job, job_id)

  cond do
    is_nil(job) ->
      {:error, :not_found}

    job.status == "started" ->
      {:error, :job_running}

    true ->
      job
      |> Job.changeset(%{"deleted_at" => DateTime.utc_now(), "status" => "deleted"})
      |> Repo.update()
  end
end
```

- [ ] **Step 5: Implement JobController**

Create `lib/distributed_task_queue_web/controllers/job_controller.ex`:

```elixir
defmodule DistributedTaskQueueWeb.JobController do
  use DistributedTaskQueueWeb, :controller

  def index(conn, params) do
    jobs = DistributedTaskQueue.list_jobs_filtered(params)
    json(conn, %{data: Enum.map(jobs, &job_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case DistributedTaskQueue.get_job(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      job -> json(conn, %{data: job_json(job)})
    end
  end

  def create(conn, params) do
    case DistributedTaskQueue.add_job(params["queue_name"] || params[:queue_name], params) do
      {:ok, job} ->
        conn |> put_status(:created) |> json(%{data: job_json(job)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case DistributedTaskQueue.delete_job(id) do
      {:ok, job} ->
        json(conn, %{data: job_json(job)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :job_running} ->
        conn |> put_status(:conflict) |> json(%{error: "job is currently running"})
    end
  end

  defp job_json(job) do
    %{
      id: job.id,
      queue_name: job.queue_name,
      worker_module: job.worker_module,
      payload: job.payload,
      status: job.status,
      attempts: job.attempts,
      max_attempts: job.max_attempts,
      error_message: job.error_message,
      scheduled_at: job.scheduled_at,
      started_at: job.started_at,
      completed_at: job.completed_at,
      attempted_by: job.attempted_by,
      inserted_at: job.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
```

- [ ] **Step 6: Run job controller tests**

```bash
mix test test/distributed_task_queue_web/controllers/job_controller_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/distributed_task_queue_web/controllers/job_controller.ex lib/distributed_task_queue.ex test/distributed_task_queue_web/controllers/job_controller_test.exs
git commit -m "feat(api): add JobController with index, show, create, delete actions"
```

---

## Task 6: Smoke test — verify routes and app boot

Manual verification that everything wires together correctly.

- [ ] **Step 1: Check all routes are registered**

```bash
mix phx.routes
```

Expected output includes:
```
GET     /api/queues               QueueController :index
POST    /api/queues               QueueController :create
POST    /api/queues/:name/start   QueueController :start
POST    /api/queues/:name/stop    QueueController :stop
GET     /api/jobs                 JobController :index
GET     /api/jobs/:id             JobController :show
POST    /api/jobs                 JobController :create
DELETE  /api/jobs/:id             JobController :delete
```

- [ ] **Step 2: Run full test suite one final time**

```bash
mix test
```

Expected: all tests pass, zero failures.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "chore: verify routes and finalize queue-boot + REST API implementation"
```

---

## Spec Coverage Checklist

| Spec requirement | Covered by |
|-----------------|-----------|
| QueueBootstrapper after WorkerSupervisor in tree | Task 2, Step 4 |
| Boot queries all Queue records | Task 2, Step 3 |
| Already-started queues skipped silently | Task 2, Step 3 + test |
| No crash on boot failure per queue | Task 2, Step 3 + test |
| `:api` pipeline with JSON accept | Task 3 (already existed in router) |
| `GET /api/queues` | Task 4 |
| `POST /api/queues` | Task 4 |
| `POST /api/queues/:name/start` | Task 4 |
| `POST /api/queues/:name/stop` | Task 4 |
| `GET /api/jobs` with filters | Task 5 |
| `GET /api/jobs/:id` | Task 5 |
| `POST /api/jobs` with optional scheduled_at | Task 5 |
| `DELETE /api/jobs/:id` soft-delete | Task 5 |
| 409 for deleting running job | Task 5, Step 4 + test |
| 409 for stopping queue with pending jobs | Task 4 test |
| 404 for unknown queue/job | Task 4 + Task 5 tests |
| 422 for missing required fields | Task 4 + Task 5 tests |
| Idempotent queue start | Task 4 test |
| Consistent `{ "data": ... }` / `{ "error": ... }` envelope | Task 4 + Task 5 |
