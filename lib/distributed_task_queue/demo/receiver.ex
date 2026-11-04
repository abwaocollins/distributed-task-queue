defmodule DistributedTaskQueue.Demo.Receiver do
  @moduledoc """
  One of the in-app demo services (Payments, Email, Warehouse) that webhooks
  are delivered to on the public demo. A visitor can switch it offline to
  watch retries pile up, then back online to watch the backlog drain.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "demo_receivers" do
    field(:name, :string)
    field(:online, :boolean, default: true)
    field(:offline_until, :utc_datetime)
    field(:failure_rate, :float, default: 0.1)

    timestamps()
  end
end
