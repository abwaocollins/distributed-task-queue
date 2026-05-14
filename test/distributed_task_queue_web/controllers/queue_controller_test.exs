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
