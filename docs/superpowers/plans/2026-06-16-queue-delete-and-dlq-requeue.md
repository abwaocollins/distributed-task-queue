# Queue Deletion + Dead-Letter Requeue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cascade queue deletion (with ETS cache invalidation) and dead-letter job requeue (single + bulk), exposed as both context functions and REST endpoints.

**Architecture:** `delete_queue/1` stops the queue's `QueueManager`, deletes all of the queue's jobs and the queue row inside a `Repo.transaction`, then invalidates the `QueueCache` ETS entry. `requeue_dead_letter_job/1` resets a dead-lettered job to a claimable `pending` state and ensures the queue's manager is running so the job is actually picked up; `requeue_all_dead_letter_jobs/0` applies it to every dead-lettered job. New routes wire all three into the existing `/api` JSON API.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, Phoenix (controllers + verified routes `~p`), ETS, ExMachina, ExUnit.

**Branch:** `feature/queue-delete-and-dlq-requeue` (already created and checked out — no branch task below).

---

## File Map

| File | Change |
|---|---|
| `lib/distributed_task_queue.ex` | Add `delete_queue/1`, `requeue_dead_letter_job/1`, `requeue_all_dead_letter_jobs/0`, private `ensure_queue_running/1` |
| `lib/distributed_task_queue_web/router.ex` | Add `DELETE /api/queues/:name`, `POST /api/jobs/:id/requeue`, `POST /api/jobs/requeue_dead_letter` |
| `lib/distributed_task_queue_web/controllers/queue_controller.ex` | Add `delete/2` |
| `lib/distributed_task_queue_web/controllers/job_controller.ex` | Add `requeue/2`, `requeue_all/2` |
| `test/distributed_task_queue_test.exs` | Add `DeleteQueueTest` + `RequeueDeadLetterTest` modules |
| `test/distributed_task_queue_web/controllers/queue_controller_test.exs` | Add `DELETE /api/queues/:name` describe block |
| `test/distributed_task_queue_web/controllers/job_controller_test.exs` | Add requeue describe blocks |

No migrations. No schema changes — every field reset by requeue is already cast by `Job.changeset/2`.

---

## Task 1: `delete_queue/1` Context Function

**Files:**
- Modify: `lib/distributed_task_queue.ex`
- Modify: `test/distributed_task_queue_test.exs`

- [ ] **Step 1: Write the failing tests**

Append this module to the end of `test/distributed_task_queue_test.exs`:

```elixir
defmodule DistributedTaskQueue.DeleteQueueTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{QueueCache, WorkerSupervisor}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "delete_queue removes the queue, its jobs, the cache entry, and stops the manager" do
    {:ok, queue} =
      DistributedTaskQueue.add_queue(%{
        "name" => "del-q-#{System.unique_integer([:positive])}",
        "max_concurrent_jobs" => 2
      })

    {:ok, _job} =
      DistributedTaskQueue.add_job(queue.name, %{
        "worker_module" => "DistributedTaskQueue.EmailWorker",
        "payload" => %{}
      })

    {:ok, _pid} = WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)

    assert {:ok, deleted} = DistributedTaskQueue.delete_queue(queue.name)
    assert deleted.name == queue.name

    assert DistributedTaskQueue.get_queue(queue.name) == nil
    assert DistributedTaskQueue.list_jobs_in_queue(queue.name) == []
    assert QueueCache.get(queue.name) == nil
    assert Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name) == []
  end

  test "delete_queue returns error for unknown queue" do
    assert DistributedTaskQueue.delete_queue("ghost-queue") == {:error, :queue_not_found}
  end
end
```

> The manager's first poll is scheduled 5s out (`@poll_interval`), so it will not claim the pending job in the brief window before `delete_queue` runs.

- [ ] **Step 2: Run the tests — expect failure**

Run: `mix test test/distributed_task_queue_test.exs`
Expected: FAIL — `DistributedTaskQueue.delete_queue/1` is undefined.

- [ ] **Step 3: Implement `delete_queue/1`**

In `lib/distributed_task_queue.ex`, add this function immediately after `stop_queue/1` (which ends around line 235):

```elixir
  def delete_queue(queue_name) do
    case get_queue(queue_name) do
      nil ->
        {:error, :queue_not_found}

      queue ->
        # Stop the manager first so it cannot claim a job that is about to be deleted.
        WorkerSupervisor.stop_queue(queue_name)

        {:ok, _} =
          Repo.transaction(fn ->
            Repo.delete_all(from j in Job, where: j.queue_name == ^queue_name)
            Repo.delete!(queue)
          end)

        QueueCache.delete(queue_name)
        {:ok, queue}
    end
  end
```

- [ ] **Step 4: Run the tests — expect pass**

Run: `mix test test/distributed_task_queue_test.exs`
Expected: PASS (both new tests, no regressions in the file).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue.ex test/distributed_task_queue_test.exs
git commit -m "feat: add delete_queue/1 with cascade job delete and cache invalidation"
```

---

## Task 2: `DELETE /api/queues/:name` Endpoint

**Files:**
- Modify: `lib/distributed_task_queue_web/router.ex`
- Modify: `lib/distributed_task_queue_web/controllers/queue_controller.ex`
- Modify: `test/distributed_task_queue_web/controllers/queue_controller_test.exs`

- [ ] **Step 1: Write the failing tests**

Append this `describe` block inside `DistributedTaskQueueWeb.QueueControllerTest` (before the final `end`):

```elixir
  describe "DELETE /api/queues/:name" do
    test "deletes an existing queue and its jobs", %{conn: conn} do
      {:ok, queue} =
        DistributedTaskQueue.add_queue(%{"name" => "ctrl-del-#{System.unique_integer([:positive])}"})

      {:ok, _job} =
        DistributedTaskQueue.add_job(queue.name, %{
          "worker_module" => "DistributedTaskQueue.EmailWorker",
          "payload" => %{}
        })

      conn = delete(conn, ~p"/api/queues/#{queue.name}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == queue.name

      assert DistributedTaskQueue.get_queue(queue.name) == nil
      assert DistributedTaskQueue.list_jobs_in_queue(queue.name) == []
    end

    test "returns 404 for unknown queue", %{conn: conn} do
      conn = delete(conn, ~p"/api/queues/ghost")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end
```

- [ ] **Step 2: Run the tests — expect failure**

Run: `mix test test/distributed_task_queue_web/controllers/queue_controller_test.exs`
Expected: FAIL — no route matches `DELETE /api/queues/:name` (and `delete/2` is undefined).

- [ ] **Step 3: Add the route**

In `lib/distributed_task_queue_web/router.ex`, add the `delete` line inside the `scope "/api"` block, right after the existing `post "/queues/:name/stop", ...` line:

```elixir
    resources "/queues", QueueController, only: [:index, :create]
    post "/queues/:name/start", QueueController, :start
    post "/queues/:name/stop",  QueueController, :stop
    delete "/queues/:name", QueueController, :delete
```

- [ ] **Step 4: Add the controller action**

In `lib/distributed_task_queue_web/controllers/queue_controller.ex`, add `delete/2` after `stop/2` (before the private `queue_json/1`):

```elixir
  def delete(conn, %{"name" => name}) do
    case DistributedTaskQueue.delete_queue(name) do
      {:ok, queue} ->
        json(conn, %{data: queue_json(queue)})

      {:error, :queue_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "queue not found"})
    end
  end
```

- [ ] **Step 5: Run the tests — expect pass**

Run: `mix test test/distributed_task_queue_web/controllers/queue_controller_test.exs`
Expected: PASS (all queue controller tests).

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: no failures.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue_web/router.ex \
        lib/distributed_task_queue_web/controllers/queue_controller.ex \
        test/distributed_task_queue_web/controllers/queue_controller_test.exs
git commit -m "feat: add DELETE /api/queues/:name endpoint"
```

---

## Task 3: Dead-Letter Requeue Context Functions

**Files:**
- Modify: `lib/distributed_task_queue.ex`
- Modify: `test/distributed_task_queue_test.exs`

- [ ] **Step 1: Write the failing tests**

Append this module to the end of `test/distributed_task_queue_test.exs`:

```elixir
defmodule DistributedTaskQueue.RequeueDeadLetterTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.WorkerSupervisor

  test "requeue_dead_letter_job resets the job to a claimable pending state" do
    queue = insert(:queue, name: "rq-#{System.unique_integer([:positive])}")
    on_exit(fn -> WorkerSupervisor.stop_queue(queue.name) end)

    job =
      insert(:job,
        queue_name: queue.name,
        status: "discarded",
        dead_letter: true,
        worker_id: 1,
        attempts: 3,
        error_message: "boom",
        discarded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

    assert {:ok, requeued} = DistributedTaskQueue.requeue_dead_letter_job(job.id)
    assert requeued.status == "pending"
    assert requeued.dead_letter == false
    assert requeued.attempts == 0
    assert is_nil(requeued.worker_id)
    assert is_nil(requeued.discarded_at)
    assert is_nil(requeued.error_message)

    # The queue's manager was (re)started so the job can be picked up.
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)
  end

  test "requeue_dead_letter_job returns error for unknown job" do
    assert DistributedTaskQueue.requeue_dead_letter_job(0) == {:error, :not_found}
  end

  test "requeue_dead_letter_job returns error for a non-dead-letter job" do
    queue = insert(:queue, name: "rq-live-#{System.unique_integer([:positive])}")
    job = insert(:job, queue_name: queue.name, status: "completed", dead_letter: false)

    assert DistributedTaskQueue.requeue_dead_letter_job(job.id) == {:error, :not_dead_letter}
  end

  test "requeue_all_dead_letter_jobs requeues every dead-lettered job" do
    queue = insert(:queue, name: "bulk-rq-#{System.unique_integer([:positive])}")
    on_exit(fn -> WorkerSupervisor.stop_queue(queue.name) end)

    a = insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 1)
    b = insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 2)
    _live = insert(:job, queue_name: queue.name, status: "pending", dead_letter: false)

    assert {:ok, 2} = DistributedTaskQueue.requeue_all_dead_letter_jobs()
    assert DistributedTaskQueue.get_job(a.id).status == "pending"
    assert DistributedTaskQueue.get_job(b.id).status == "pending"
    assert DistributedTaskQueue.list_dead_letter_jobs() == []
  end
end
```

- [ ] **Step 2: Run the tests — expect failure**

Run: `mix test test/distributed_task_queue_test.exs`
Expected: FAIL — `requeue_dead_letter_job/1` and `requeue_all_dead_letter_jobs/0` are undefined.

- [ ] **Step 3: Implement the requeue functions**

In `lib/distributed_task_queue.ex`, add these three functions after `list_dead_letter_jobs/0` (around line 59):

```elixir
  def requeue_dead_letter_job(job_id) do
    job = Repo.get(Job, job_id)

    cond do
      is_nil(job) ->
        {:error, :not_found}

      job.dead_letter != true ->
        {:error, :not_dead_letter}

      true ->
        result =
          job
          |> Job.changeset(%{
            "status" => "pending",
            "dead_letter" => false,
            "attempts" => 0,
            "worker_id" => nil,
            "error_message" => nil,
            "discarded_at" => nil,
            "next_retry_at" => nil,
            "started_at" => nil,
            "completed_at" => nil
          })
          |> Repo.update()

        case result do
          {:ok, updated} ->
            ensure_queue_running(updated.queue_name)
            {:ok, updated}

          other ->
            other
        end
    end
  end

  def requeue_all_dead_letter_jobs do
    count =
      list_dead_letter_jobs()
      |> Enum.reduce(0, fn job, acc ->
        case requeue_dead_letter_job(job.id) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    {:ok, count}
  end

  # Start the queue's manager if it isn't already running, so a requeued job is
  # actually claimed. Idempotent: an already-running manager returns
  # {:error, {:already_started, _}}, which we ignore. If the queue row is gone,
  # there is nothing to start.
  defp ensure_queue_running(queue_name) do
    case get_queue(queue_name) do
      nil ->
        :ok

      queue ->
        WorkerSupervisor.start_queue(queue_name, queue.max_concurrent_jobs)
        :ok
    end
  end
```

- [ ] **Step 4: Run the tests — expect pass**

Run: `mix test test/distributed_task_queue_test.exs`
Expected: PASS (all four new tests, no regressions).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue.ex test/distributed_task_queue_test.exs
git commit -m "feat: add requeue_dead_letter_job/1 and requeue_all_dead_letter_jobs/0"
```

---

## Task 4: Dead-Letter Requeue Endpoints

**Files:**
- Modify: `lib/distributed_task_queue_web/router.ex`
- Modify: `lib/distributed_task_queue_web/controllers/job_controller.ex`
- Modify: `test/distributed_task_queue_web/controllers/job_controller_test.exs`

- [ ] **Step 1: Write the failing tests**

Append these two `describe` blocks inside `DistributedTaskQueueWeb.JobControllerTest` (before the final `end`):

```elixir
  describe "POST /api/jobs/:id/requeue" do
    test "requeues a dead-letter job", %{conn: conn} do
      queue = insert(:queue, name: "ctrl-rq-#{System.unique_integer([:positive])}")
      on_exit(fn -> DistributedTaskQueue.WorkerSupervisor.stop_queue(queue.name) end)
      job = insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 1)

      conn = post(conn, ~p"/api/jobs/#{job.id}/requeue")
      assert %{"data" => %{"status" => "pending"}} = json_response(conn, 200)
    end

    test "returns 404 for unknown job", %{conn: conn} do
      conn = post(conn, ~p"/api/jobs/0/requeue")
      assert %{"error" => _} = json_response(conn, 404)
    end

    test "returns 422 for a non-dead-letter job", %{conn: conn} do
      job = insert(:job, status: "completed", dead_letter: false)
      conn = post(conn, ~p"/api/jobs/#{job.id}/requeue")
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "POST /api/jobs/requeue_dead_letter" do
    test "requeues all dead-letter jobs and returns the count", %{conn: conn} do
      queue = insert(:queue, name: "ctrl-bulk-#{System.unique_integer([:positive])}")
      on_exit(fn -> DistributedTaskQueue.WorkerSupervisor.stop_queue(queue.name) end)
      insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 1)
      insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 2)

      conn = post(conn, ~p"/api/jobs/requeue_dead_letter")
      assert %{"data" => %{"requeued" => 2}} = json_response(conn, 200)
    end
  end
```

- [ ] **Step 2: Run the tests — expect failure**

Run: `mix test test/distributed_task_queue_web/controllers/job_controller_test.exs`
Expected: FAIL — no routes match `POST /api/jobs/:id/requeue` or `POST /api/jobs/requeue_dead_letter`.

- [ ] **Step 3: Add the routes**

In `lib/distributed_task_queue_web/router.ex`, add the two `post` lines inside the `scope "/api"` block, immediately **before** the `resources "/jobs", ...` line (so the static `requeue_dead_letter` segment is not captured as a job `:id`):

```elixir
    post "/jobs/:id/requeue", JobController, :requeue
    post "/jobs/requeue_dead_letter", JobController, :requeue_all
    resources "/jobs", JobController, only: [:index, :show, :create, :delete]
```

- [ ] **Step 4: Add the controller actions**

In `lib/distributed_task_queue_web/controllers/job_controller.ex`, add `requeue/2` and `requeue_all/2` after `delete/2` (before the private `job_json/1`):

```elixir
  def requeue(conn, %{"id" => id}) do
    case DistributedTaskQueue.requeue_dead_letter_job(id) do
      {:ok, job} ->
        json(conn, %{data: job_json(job)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :not_dead_letter} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "job is not a dead-letter job"})
    end
  end

  def requeue_all(conn, _params) do
    {:ok, count} = DistributedTaskQueue.requeue_all_dead_letter_jobs()
    json(conn, %{data: %{requeued: count}})
  end
```

- [ ] **Step 5: Run the tests — expect pass**

Run: `mix test test/distributed_task_queue_web/controllers/job_controller_test.exs`
Expected: PASS (all job controller tests).

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: no failures.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue_web/router.ex \
        lib/distributed_task_queue_web/controllers/job_controller.ex \
        test/distributed_task_queue_web/controllers/job_controller_test.exs
git commit -m "feat: add dead-letter requeue endpoints (single + bulk)"
```

---

## Done — All Tasks Complete

Verify final state:

Run: `mix test`
Expected: full suite green.

Summary of what was built:

- **`delete_queue/1`** — stops the queue's `QueueManager`, cascade-deletes all of the queue's jobs and the queue row in one transaction, and invalidates the `QueueCache` ETS entry. Exposed as `DELETE /api/queues/:name` (200 / 404).
- **`requeue_dead_letter_job/1`** — resets a dead-lettered job to a fresh `pending` state (`attempts: 0`, `worker_id: nil`, `dead_letter: false`, timestamps cleared) and ensures the queue's manager is running. Exposed as `POST /api/jobs/:id/requeue` (200 / 404 / 422).
- **`requeue_all_dead_letter_jobs/0`** — requeues every dead-lettered job, returns `{:ok, count}`. Exposed as `POST /api/jobs/requeue_dead_letter` (200 with `{requeued: N}`).
