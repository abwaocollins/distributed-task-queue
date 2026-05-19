defmodule DistributedTaskQueue.CronJob do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cron_jobs" do
    field :name, :string
    field :description, :string
    field :worker_module, :string
    field :queue_name, :string
    field :payload, :map, default: %{}
    field :max_attempts, :integer, default: 3
    field :cron_expression, :string
    field :interval_seconds, :integer
    field :overlap, :boolean, default: false
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime

    timestamps()
  end

  def changeset(cron_job, attrs) do
    cron_job
    |> cast(attrs, [
      :name, :description, :worker_module, :queue_name, :payload,
      :max_attempts, :cron_expression, :interval_seconds,
      :overlap, :enabled, :last_run_at, :next_run_at
    ])
    |> validate_required([:name, :worker_module, :queue_name, :payload])
    |> unique_constraint(:name)
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_schedule()
    |> validate_cron_expression()
  end

  def compute_next_run_at(%__MODULE__{interval_seconds: seconds}) when not is_nil(seconds) do
    DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)
  end

  def compute_next_run_at(%__MODULE__{cron_expression: expr}) when not is_nil(expr) do
    {:ok, cron} = Crontab.CronExpression.Parser.parse(expr)
    {:ok, naive_next} = Crontab.Scheduler.get_next_run_date(cron, NaiveDateTime.utc_now())
    DateTime.from_naive!(naive_next, "Etc/UTC")
  end

  defp validate_schedule(changeset) do
    cron_expr = get_field(changeset, :cron_expression)
    interval = get_field(changeset, :interval_seconds)

    cond do
      not is_nil(cron_expr) and not is_nil(interval) ->
        add_error(changeset, :cron_expression, "only one of cron_expression or interval_seconds may be set")
      is_nil(cron_expr) and is_nil(interval) ->
        add_error(changeset, :cron_expression, "either cron_expression or interval_seconds must be set")
      true ->
        changeset
    end
  end

  defp validate_cron_expression(changeset) do
    case get_field(changeset, :cron_expression) do
      nil -> changeset
      expr ->
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
        end
    end
  end
end
