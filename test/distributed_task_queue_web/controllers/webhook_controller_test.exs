defmodule DistributedTaskQueueWeb.WebhookControllerTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  alias DistributedTaskQueue.Webhooks

  # A literal IP needs no DNS lookup, and test config allows private targets.
  @url "http://127.0.0.1:9/hook"

  defp set_env(key, value) do
    old = Application.get_env(:distributed_task_queue, key)
    Application.put_env(:distributed_task_queue, key, value)

    on_exit(fn ->
      if old,
        do: Application.put_env(:distributed_task_queue, key, old),
        else: Application.delete_env(:distributed_task_queue, key)
    end)
  end

  describe "POST /api/webhooks" do
    test "with delay_seconds schedules it", %{conn: conn} do
      conn = post(conn, ~p"/api/webhooks", %{"url" => @url, "delay_seconds" => 60})
      assert %{"data" => job} = json_response(conn, 201)

      assert job["worker_module"] == "DistributedTaskQueue.Workers.Webhook"
      assert job["queue_name"] == "webhooks"
      assert job["max_attempts"] == 5
      assert job["payload"]["url"] == @url

      {:ok, at, _} = DateTime.from_iso8601(job["scheduled_at"])
      assert_in_delta DateTime.diff(at, DateTime.utc_now()), 60, 5
    end

    test "with run_at", %{conn: conn} do
      conn =
        post(conn, ~p"/api/webhooks", %{"url" => @url, "run_at" => "2099-01-01T12:00:00+02:00"})

      assert %{"data" => job} = json_response(conn, 201)
      assert job["scheduled_at"] == "2099-01-01T10:00:00Z"
    end

    test "422 for a bad url, method or header", %{conn: conn} do
      for params <- [
            %{"url" => "ftp://example.com"},
            %{"url" => @url, "method" => "TRACE"},
            %{"url" => @url, "headers" => %{"bad name" => "x"}}
          ] do
        assert %{"error" => error} =
                 conn |> post(~p"/api/webhooks", params) |> json_response(422)

        assert error =~ "payload"
      end
    end

    test "422 for a bad schedule", %{conn: conn} do
      for extra <- [
            %{"delay_seconds" => -1},
            %{"delay_seconds" => 31_536_001},
            %{"delay_seconds" => "5"},
            %{"run_at" => "tomorrow"},
            %{"run_at" => "2099-01-01T12:00:00"},
            %{"run_at" => "2099-01-01T12:00:00Z", "delay_seconds" => 5}
          ] do
        assert %{"error" => error} =
                 conn
                 |> post(~p"/api/webhooks", Map.put(extra, "url", @url))
                 |> json_response(422)

        assert error =~ "scheduled_at"
      end
    end

    test "422 for a non-receiver url in demo_receivers mode", %{conn: conn} do
      set_env(:webhooks, targets: :demo_receivers)

      assert %{"error" => error} =
               conn |> post(~p"/api/webhooks", %{"url" => @url}) |> json_response(422)

      assert error =~ "demo receivers"
    end
  end

  describe "jobs API for webhook jobs" do
    test "GET /api/jobs/:id includes deliveries and redacts headers", %{conn: conn} do
      {:ok, job} =
        Webhooks.enqueue(%{
          "url" => @url,
          "headers" => %{"Authorization" => "Bearer s3cret", "X-Trace" => "abc"}
        })

      {:ok, _} =
        Webhooks.record_delivery(job, %{status_code: 500, duration_ms: 12, response_body: "oops"})

      assert %{"data" => data} = conn |> get(~p"/api/jobs/#{job.id}") |> json_response(200)
      assert data["payload"]["headers"] == %{"authorization" => "••••", "x-trace" => "abc"}

      assert [
               %{
                 "number" => 1,
                 "status_code" => 500,
                 "duration_ms" => 12,
                 "response_body" => "oops"
               }
             ] = data["deliveries"]

      # Redaction is for display only; the stored request is untouched.
      assert DistributedTaskQueue.get_job(job.id).payload["headers"]["authorization"] ==
               "Bearer s3cret"
    end

    test "non-webhook jobs have no deliveries", %{conn: conn} do
      job = insert(:job)
      assert %{"data" => data} = conn |> get(~p"/api/jobs/#{job.id}") |> json_response(200)
      refute Map.has_key?(data, "deliveries")
    end
  end

  describe "POST /api/cron_jobs with a webhook" do
    test "accepts a webhook object", %{conn: conn} do
      params = %{
        "name" => "ping",
        "queue_name" => insert(:queue).name,
        "interval_seconds" => 60,
        "webhook" => %{"url" => @url, "method" => "get"}
      }

      assert %{"data" => cron} = conn |> post(~p"/api/cron_jobs", params) |> json_response(201)
      assert cron["worker_module"] == "DistributedTaskQueue.Workers.Webhook"
      assert cron["payload"]["method"] == "GET"
      assert cron["payload"]["url"] == @url
    end

    test "422 for an invalid webhook object", %{conn: conn} do
      params = %{
        "name" => "bad",
        "queue_name" => insert(:queue).name,
        "interval_seconds" => 60,
        "webhook" => %{"url" => "nope"}
      }

      assert %{"error" => error} = conn |> post(~p"/api/cron_jobs", params) |> json_response(422)
      assert error =~ "payload url:"
    end

    test "interval below 10s is refused only in demo_receivers mode", %{conn: conn} do
      params = fn name ->
        %{
          "name" => name,
          "queue_name" => insert(:queue).name,
          "interval_seconds" => 5,
          "webhook" => %{"url" => @url}
        }
      end

      assert conn |> post(~p"/api/cron_jobs", params.("fast-any")) |> json_response(201)

      set_env(:webhooks, targets: :demo_receivers)

      # The url is not a receiver either, so look for the interval message.
      assert %{"error" => error} =
               conn |> post(~p"/api/cron_jobs", params.("fast-demo")) |> json_response(422)

      assert error =~ "interval_seconds must be greater than or equal to 10"
    end
  end

  describe "ensure_queue/0" do
    test "boot creates the webhooks queue once and never changes it" do
      assert :ok = Webhooks.ensure_queue()
      queue = DistributedTaskQueue.get_queue("webhooks")
      assert queue.max_concurrent_jobs == 10

      {:ok, _} = DistributedTaskQueue.update_queue(queue, %{"max_concurrent_jobs" => 3})
      assert :ok = Webhooks.ensure_queue()
      assert DistributedTaskQueue.get_queue("webhooks").max_concurrent_jobs == 3
    end
  end
end
