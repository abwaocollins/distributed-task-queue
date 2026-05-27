defmodule DistributedTaskQueue.QueueCache do
  use GenServer

  @table :queue_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, :ok}
  end

  def put(%{name: name} = queue) do
    :ets.insert(@table, {name, queue})
    :ok
  end

  def get(queue_name) do
    case :ets.lookup(@table, queue_name) do
      [{^queue_name, queue}] -> queue
      [] -> nil
    end
  end

  def delete(queue_name) do
    :ets.delete(@table, queue_name)
    :ok
  end

  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_name, queue} -> queue end)
  end
end
