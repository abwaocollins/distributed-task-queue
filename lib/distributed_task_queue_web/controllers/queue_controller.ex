defmodule DistributedTaskQueueWeb.QueueController do
  use DistributedTaskQueueWeb, :controller

  def index(conn, _params) do
    queues = DistributedTaskQueue.list_queues()
    json(conn, %{data: Enum.map(queues, &queue_json/1)})
  end

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

  def delete(conn, %{"name" => name}) do
    case DistributedTaskQueue.delete_queue(name) do
      {:ok, queue} ->
        json(conn, %{data: queue_json(queue)})

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
