defmodule DistributedTaskQueue.Worker do
  use GenServer

  def start_link(id) do
    GenServer.start_link(__MODULE__, %{id: id}, name: via(id))
  end
  defp via(id) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, id}}
  end

  def init(state) do
    {:ok, state}
  end

end
