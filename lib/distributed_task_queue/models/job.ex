defmodule DistributedTaskQueue.Job do
  use Ecto.Schema
  import Ecto.Changeset

  schema "jobs" do
    field(:payload, :map)
    field(:worker_module, :string)
    field(:queue_name, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:max_attempts, :integer, default: 3)
    field(:error_message, :string)
    field(:scheduled_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:next_retry_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:discarded_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)

    timestamps()
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :payload,
      :worker_module,
      :queue_name,
      :status,
      :attempts,
      :max_attempts,
      :error_message,
      :scheduled_at,
      :started_at,
      :next_retry_at,
      :completed_at,
      :discarded_at,
      :deleted_at
    ])
    |> validate_required([:payload, :queue_name])
  end
end
