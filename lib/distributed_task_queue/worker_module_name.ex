defmodule DistributedTaskQueue.WorkerModuleName do
  @moduledoc """
  Insert-time validation for the `worker_module` field.

  This checks *shape*, not existence. In a distributed deployment the node
  enqueueing a job need not have the worker module loaded — a thin API tier can
  enqueue work that only worker nodes know how to run. Rejecting unloaded
  modules here would break that topology and make rolling deploys fail.

  Existence and behaviour are enforced at dispatch instead, by
  `DistributedTaskQueue.Worker.resolve/1`. That is the security boundary; this
  is fail-fast feedback so obviously malformed input gets a 422 at the API
  rather than a job that dies later in a worker.
  """

  import Ecto.Changeset

  # An Elixir alias: dot-separated segments, each starting uppercase.
  @module_name ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/

  @doc """
  Validates that `field` on `changeset` looks like an Elixir module name.
  """
  def validate(changeset, field) do
    validate_format(changeset, field, @module_name,
      message: "is not a valid Elixir module name"
    )
  end
end
