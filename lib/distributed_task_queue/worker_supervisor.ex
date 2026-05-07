defmodule DistributedTaskQueue.WorkerSupervisor do
  use DynamicSupervisor
  alias DistributedTaskQueue.QueueManager

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_queue(queue_name, concurrency) do
    DynamicSupervisor.start_child(__MODULE__, {QueueManager, {queue_name, concurrency}})
  end

  def stop_queue(queue_name) do
    case Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_running}
    end
  end
end
