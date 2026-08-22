defmodule DistributedTaskQueue.CronJob do
  use Ecto.Schema
  import Ecto.Changeset

  @utc "Etc/UTC"

  schema "cron_jobs" do
    field :name, :string
    field :description, :string
    field :worker_module, :string
    field :queue_name, :string
    field :payload, :map, default: %{}
    field :max_attempts, :integer, default: 3
    field :cron_expression, :string
    field :interval_seconds, :integer
    field :timezone, :string
    field :overlap, :boolean, default: false
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime

    has_many(:jobs, DistributedTaskQueue.Job)

    timestamps()
  end

  def changeset(cron_job, attrs) do
    cron_job
    |> cast(attrs, [
      :name, :description, :worker_module, :queue_name, :payload,
      :max_attempts, :cron_expression, :interval_seconds, :timezone,
      :overlap, :enabled, :last_run_at, :next_run_at
    ])
    |> validate_required([:name, :worker_module, :queue_name, :payload])
    |> DistributedTaskQueue.WorkerModuleName.validate(:worker_module)
    |> unique_constraint(:name)
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_schedule()
    |> validate_cron_expression()
    |> validate_timezone()
  end

  @doc """
  When this cron should next run, as a UTC datetime.

  Interval schedules are relative to *now*, so the gap between runs is measured
  from the previous fire. Cron expressions are absolute wall-clock slots,
  resolved in the job's `timezone` (UTC when unset).
  """
  def compute_next_run_at(%__MODULE__{interval_seconds: seconds}) when not is_nil(seconds) do
    DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)
  end

  def compute_next_run_at(%__MODULE__{cron_expression: expr, timezone: timezone})
      when not is_nil(expr) do
    zone = timezone || @utc
    {:ok, cron} = Crontab.CronExpression.Parser.parse(expr)

    local_now =
      DateTime.utc_now()
      |> DateTime.shift_zone!(zone)
      |> DateTime.to_naive()

    {:ok, naive_next} = Crontab.Scheduler.get_next_run_date(cron, local_now)

    naive_next
    |> local_to_utc(zone)
    |> DateTime.truncate(:second)
  end

  def compute_next_run_at(%__MODULE__{}),
    do: raise(ArgumentError, "CronJob must have cron_expression or interval_seconds set")

  # Daylight-saving transitions make some local times ambiguous or non-existent,
  # so a plain from_naive! would crash the scheduler twice a year.
  defp local_to_utc(naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, dt} ->
        DateTime.shift_zone!(dt, @utc)

      # Spring forward: this local time never happens. Run at the instant the
      # clock jumps past it rather than skipping the day.
      {:gap, _just_before, just_after} ->
        DateTime.shift_zone!(just_after, @utc)

      # Fall back: this local time happens twice. Take the first, so the job
      # runs once at the earlier instant instead of an hour late.
      {:ambiguous, first, _second} ->
        DateTime.shift_zone!(first, @utc)

      {:error, reason} ->
        raise ArgumentError, "cannot resolve #{naive} in timezone #{zone}: #{inspect(reason)}"
    end
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
    if changeset.valid? do
      validate_parsable_cron(changeset, get_field(changeset, :cron_expression))
    else
      changeset
    end
  end

  defp validate_parsable_cron(changeset, nil), do: changeset

  defp validate_parsable_cron(changeset, expr) do
    case Crontab.CronExpression.Parser.parse(expr) do
      {:ok, _} -> changeset
      {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
    end
  end

  defp validate_timezone(changeset) do
    if changeset.valid? do
      case get_field(changeset, :timezone) do
        nil ->
          changeset

        zone ->
          changeset
          |> validate_known_timezone(zone)
          |> validate_timezone_has_cron_expression()
      end
    else
      changeset
    end
  end

  defp validate_known_timezone(changeset, zone) do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _} -> changeset
      {:error, _} -> add_error(changeset, :timezone, "is not a known time zone")
    end
  end

  defp validate_timezone_has_cron_expression(changeset) do
    if is_nil(get_field(changeset, :cron_expression)) do
      add_error(changeset, :timezone, "only applies to cron_expression schedules")
    else
      changeset
    end
  end
end
