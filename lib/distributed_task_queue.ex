defmodule DistributedTaskQueue do
  @moduledoc """
  DistributedTaskQueue keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  alias DistributedTaskQueue.WorkerSupervisor
  alias DistributedTaskQueue.Worker

  def start_worker(id) do
    spec = {Worker, id}
    DynamicSupervisor.start_child(WorkerSupervisor, spec)
  end
end
