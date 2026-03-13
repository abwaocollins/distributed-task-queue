defmodule DistributedTaskQueue.Queue do
  use Ecto.Schema
  import Ecto.Changeset

  schema "queues" do
    field :name, :string
    field :description, :string
    field :max_concurrent_jobs, :integer, default: 5

    timestamps()
  end

  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:name, :description, :max_concurrent_jobs])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
