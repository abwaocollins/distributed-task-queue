defmodule DistributedTaskQueueWeb.JobControllerTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  describe "GET /api/jobs" do
    test "returns all jobs when no filters", %{conn: conn} do
      insert(:job)
      insert(:job)
      conn = get(conn, ~p"/api/jobs")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) >= 2
    end

    test "filters by queue name", %{conn: conn} do
      queue = insert(:queue, name: "target")
      insert(:job, queue_name: queue.name)
      insert(:job)
      conn = get(conn, ~p"/api/jobs?queue=target")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) >= 1
      assert Enum.all?(jobs, fn j -> j["queue_name"] == "target" end)
    end

    test "filters by status", %{conn: conn} do
      insert(:job, status: "pending")
      insert(:job, status: "completed")
      conn = get(conn, ~p"/api/jobs?status=pending")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) >= 1
      assert Enum.all?(jobs, fn j -> j["status"] == "pending" end)
    end

    test "filters by both queue and status", %{conn: conn} do
      queue = insert(:queue, name: "q")
      insert(:job, queue_name: queue.name, status: "pending")
      insert(:job, queue_name: queue.name, status: "completed")
      insert(:job, status: "pending")
      conn = get(conn, ~p"/api/jobs?queue=q&status=pending")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
      assert hd(jobs)["queue_name"] == "q"
      assert hd(jobs)["status"] == "pending"
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

    test "enqueues with optional scheduled_at for future execution", %{conn: conn} do
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

    test "returns 422 when worker_module is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/jobs", %{queue_name: "emails", payload: %{}})
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
end
