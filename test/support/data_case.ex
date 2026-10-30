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

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    DistributedTaskQueue.DataCase.setup_sandbox(tags)
  end

  def setup_sandbox(tags) do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(DistributedTaskQueue.Repo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # add_job/2 starts queue managers. Stop them before the sandbox owner goes
    # (on_exit runs in reverse order), or they outlive the test and crash on
    # their next query. Sync tests only: an async test cannot share its sandbox
    # with a manager anyway, and this would stop other tests' managers.
    unless tags[:async], do: on_exit(&stop_queue_managers/0)

    :ok
  end

  defp stop_queue_managers do
    DistributedTaskQueue.WorkerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, child, _, _} ->
      DynamicSupervisor.terminate_child(DistributedTaskQueue.WorkerSupervisor, child)
    end)
  end
end
