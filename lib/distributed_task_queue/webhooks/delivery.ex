defmodule DistributedTaskQueue.Webhooks.Delivery do
  @moduledoc """
  One HTTP attempt made for a webhook job. `number` counts attempts across
  requeues, so history is never overwritten.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "webhook_deliveries" do
    field(:number, :integer)
    field(:method, :string)
    field(:url, :string)
    field(:status_code, :integer)
    field(:duration_ms, :integer)
    field(:response_body, :string)
    field(:error, :string)
    belongs_to(:job, DistributedTaskQueue.Job)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:number, :method, :url, :status_code, :duration_ms, :response_body, :error])
    |> validate_required([:number])
    |> unique_constraint([:job_id, :number])
  end
end
