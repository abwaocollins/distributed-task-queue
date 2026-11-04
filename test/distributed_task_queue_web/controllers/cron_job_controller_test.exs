defmodule DistributedTaskQueueWeb.CronJobControllerTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  alias DistributedTaskQueue.{CronJob, Repo}

  defp past(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  describe "GET /api/cron_jobs" do
    test "lists cron jobs", %{conn: conn} do
      cron = insert(:cron_job)
      assert %{"data" => crons} = json_response(get(conn, ~p"/api/cron_jobs"), 200)
      assert Enum.any?(crons, &(&1["id"] == cron.id and &1["name"] == cron.name))
    end
  end

  describe "GET /api/cron_jobs/:id" do
    test "shows one", %{conn: conn} do
      cron = insert(:cron_job)

      assert %{"data" => %{"id" => id}} =
               json_response(get(conn, ~p"/api/cron_jobs/#{cron.id}"), 200)

      assert id == cron.id
    end

    test "404s for an unknown or malformed id", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/cron_jobs/0"), 404)
      assert json_response(get(conn, ~p"/api/cron_jobs/abc"), 404)
    end
  end

  describe "POST /api/cron_jobs" do
    test "creates a cron job with its first run computed", %{conn: conn} do
      queue = insert(:queue)

      conn =
        post(conn, ~p"/api/cron_jobs", %{
          "name" => "nightly",
          "queue_name" => queue.name,
          "worker_module" => "DistributedTaskQueue.EmailWorker",
          "cron_expression" => "0 2 * * *",
          "timezone" => "Africa/Nairobi",
          "payload" => %{"to" => "ops@example.com"}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "nightly"
      assert data["enabled"]
      assert data["next_run_at"]
    end

    test "ignores a client-supplied next_run_at", %{conn: conn} do
      queue = insert(:queue)

      conn =
        post(conn, ~p"/api/cron_jobs", %{
          "name" => "no-backdating",
          "queue_name" => queue.name,
          "worker_module" => "DistributedTaskQueue.EmailWorker",
          "interval_seconds" => 600,
          "payload" => %{},
          "next_run_at" => "2000-01-01T00:00:00Z"
        })

      assert %{"data" => %{"next_run_at" => next}} = json_response(conn, 201)
      {:ok, next, _} = DateTime.from_iso8601(next)
      assert DateTime.compare(next, DateTime.utc_now()) == :gt
    end

    test "422s on an invalid schedule", %{conn: conn} do
      conn =
        post(conn, ~p"/api/cron_jobs", %{
          "name" => "bad",
          "queue_name" => "q",
          "worker_module" => "DistributedTaskQueue.EmailWorker",
          "payload" => %{}
        })

      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/cron_jobs/:id" do
    test "updates fields", %{conn: conn} do
      cron = insert(:cron_job, overlap: false)
      conn = patch(conn, ~p"/api/cron_jobs/#{cron.id}", %{"overlap" => true})
      assert %{"data" => %{"overlap" => true}} = json_response(conn, 200)
    end

    test "does not enable through update", %{conn: conn} do
      cron = insert(:cron_job, enabled: false)
      patch(conn, ~p"/api/cron_jobs/#{cron.id}", %{"enabled" => true})
      refute Repo.get!(CronJob, cron.id).enabled
    end

    test "422s on invalid attrs", %{conn: conn} do
      cron = insert(:cron_job)
      conn = patch(conn, ~p"/api/cron_jobs/#{cron.id}", %{"worker_module" => "not a module"})
      assert json_response(conn, 422)
    end
  end

  describe "POST /api/cron_jobs/:id/enable and /disable" do
    test "enabling restarts the schedule from now", %{conn: conn} do
      cron = insert(:cron_job, enabled: false, next_run_at: past(7 * 86_400))

      assert %{"data" => %{"enabled" => true, "next_run_at" => next}} =
               json_response(post(conn, ~p"/api/cron_jobs/#{cron.id}/enable"), 200)

      {:ok, next, _} = DateTime.from_iso8601(next)
      assert DateTime.compare(next, DateTime.utc_now()) == :gt
    end

    test "disables", %{conn: conn} do
      cron = insert(:cron_job, enabled: true)

      assert %{"data" => %{"enabled" => false}} =
               json_response(post(conn, ~p"/api/cron_jobs/#{cron.id}/disable"), 200)
    end
  end

  describe "DELETE /api/cron_jobs/:id" do
    test "deletes", %{conn: conn} do
      cron = insert(:cron_job)
      assert json_response(delete(conn, ~p"/api/cron_jobs/#{cron.id}"), 200)
      refute Repo.get(CronJob, cron.id)
    end

    test "404s for an unknown id", %{conn: conn} do
      assert json_response(delete(conn, ~p"/api/cron_jobs/0"), 404)
    end
  end
end
