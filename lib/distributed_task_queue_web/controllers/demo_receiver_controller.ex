defmodule DistributedTaskQueueWeb.DemoReceiverController do
  @moduledoc """
  Stands in for an external system (payments, email, warehouse) on the public
  demo. It is deliberately unauthenticated: the service calls it exactly as it
  would call a stranger's endpoint.
  """

  use DistributedTaskQueueWeb, :controller

  alias DistributedTaskQueue.Demo.Receivers

  def receive(conn, %{"name" => name}) do
    with true <- Application.get_env(:distributed_task_queue, :demo_mode) == true,
         %{} = receiver <- Receivers.get(name) do
      respond(conn, receiver)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp respond(conn, %{online: false, name: name}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "#{String.capitalize(name)} is offline"})
  end

  defp respond(conn, receiver) do
    delay = Application.get_env(:distributed_task_queue, :demo_receiver_delay_ms, 50..800)
    Process.sleep(Enum.random(delay))

    if :rand.uniform() < receiver.failure_rate do
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "#{String.capitalize(receiver.name)} had a hiccup"})
    else
      json(conn, %{ok: true, receiver: receiver.name})
    end
  end
end
