defmodule DistributedTaskQueueWeb.DemoReceiverControllerTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  alias DistributedTaskQueue.Demo.{Receiver, Receivers}
  alias DistributedTaskQueue.Repo

  setup do
    Receivers.ensure_all()
    previous = Application.get_env(:distributed_task_queue, :demo_mode)
    Application.put_env(:distributed_task_queue, :demo_mode, true)
    on_exit(fn -> Application.put_env(:distributed_task_queue, :demo_mode, previous) end)
    :ok
  end

  defp set_rate(name, rate) do
    Receiver
    |> Repo.get_by!(name: name)
    |> Ecto.Changeset.change(failure_rate: rate)
    |> Repo.update!()
  end

  test "404 when demo mode is off", %{conn: conn} do
    Application.put_env(:distributed_task_queue, :demo_mode, false)
    assert conn |> post("/demo/receivers/payments", %{}) |> json_response(404)
  end

  test "404 for an unknown receiver", %{conn: conn} do
    assert conn |> post("/demo/receivers/nope", %{}) |> json_response(404)
  end

  test "503 while offline", %{conn: conn} do
    {:ok, _} = Receivers.set_online("payments", false)

    assert %{"error" => "Payments is offline"} =
             conn |> post("/demo/receivers/payments", %{}) |> json_response(503)
  end

  test "200 when online with failure_rate 0, with no accept header and any verb", %{conn: conn} do
    set_rate("email", 0.0)
    conn = delete_req_header(conn, "accept")

    assert %{"ok" => true, "receiver" => "email"} =
             conn |> put("/demo/receivers/email", %{}) |> json_response(200)
  end

  test "503 when the failure draw loses", %{conn: conn} do
    set_rate("warehouse", 1.0)
    assert conn |> post("/demo/receivers/warehouse", %{}) |> json_response(503)
  end
end
