defmodule DistributedTaskQueue.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias DistributedTaskQueue.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DistributedTaskQueue.DataCase
      import DistributedTaskQueue.Factory
    end
  end

  setup tags do
    DistributedTaskQueue.DataCase.setup_sandbox(tags)
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DistributedTaskQueue.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
