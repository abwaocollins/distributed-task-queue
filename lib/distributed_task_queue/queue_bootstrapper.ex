defmodule DistributedTaskQueue.QueueBootstrapper do
  use GenServer, restart: :transient
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

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
    boot()
  end
end
