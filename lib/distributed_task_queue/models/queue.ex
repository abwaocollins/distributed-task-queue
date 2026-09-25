defmodule DistributedTaskQueue.Queue do
  use Ecto.Schema
  import Ecto.Changeset

  schema "queues" do
    field(:name, :string)
    field(:description, :string)
    field(:max_concurrent_jobs, :integer, default: 5)
    field(:paused, :boolean, default: false)

    timestamps()
  end

  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:name, :description, :max_concurrent_jobs, :paused])
    |> validate_required([:name])
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
    |> unique_constraint(:name)
  end

  @doc """
  Changes allowed on an existing queue. The name is fixed: jobs and cron jobs
  reference a queue by name, so renaming would orphan them.
  """
  def update_changeset(queue, attrs) do
    queue
    |> cast(attrs, [:description, :max_concurrent_jobs])
    |> validate_required([:max_concurrent_jobs])
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
  end
end
