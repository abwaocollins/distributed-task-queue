defmodule DistributedTaskQueue.WorkerSupervisor do
  use DynamicSupervisor
  alias DistributedTaskQueue.Worker

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_queue(queue_name, concurrency) do
    Enum.map(1..concurrency, fn i ->
      DynamicSupervisor.start_child(__MODULE__, {Worker, {i, queue_name}})
    end)
  end
end
