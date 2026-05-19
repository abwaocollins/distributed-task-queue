defmodule DistributedTaskQueue.CronScheduler do
  use GenServer

  alias DistributedTaskQueue.{Repo, CronJob, Job}
  import Ecto.Query

  @fallback_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def fire_due_crons do
    now = DateTime.utc_now()

    Repo.all(
      from c in CronJob,
        where: c.enabled == true and not is_nil(c.next_run_at) and c.next_run_at <= ^now
    )
    |> Enum.each(&maybe_fire/1)
  end

  @impl true
  def init(_opts) do
    initialize_null_next_run_ats()
    schedule_next_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    fire_due_crons()
    schedule_next_poll()
    {:noreply, state}
  end

  defp maybe_fire(cron) do
    if cron.overlap or no_active_jobs?(cron.id) do
      case DistributedTaskQueue.add_job(cron.queue_name, %{
             "worker_module" => cron.worker_module,
             "payload" => cron.payload,
             "max_attempts" => cron.max_attempts,
             "cron_job_id" => cron.id
           }) do
        {:ok, _job} ->
          next_run_at = CronJob.compute_next_run_at(cron)

          cron
          |> CronJob.changeset(%{
            last_run_at: DateTime.utc_now() |> DateTime.truncate(:second),
            next_run_at: next_run_at
          })
          |> Repo.update!()

        {:error, reason} ->
          require Logger
          Logger.error("CronScheduler: failed to enqueue job for cron #{cron.id}: #{inspect(reason)}")
      end
    end
  end

  defp no_active_jobs?(cron_id) do
    not Repo.exists?(
      from j in Job,
        where: j.cron_job_id == ^cron_id and j.status in ["pending", "started"]
    )
  end

  defp schedule_next_poll do
    Process.send_after(self(), :poll, next_poll_delay_ms())
  end

  defp next_poll_delay_ms do
    now = DateTime.utc_now()

    case Repo.one(
           from c in CronJob,
             where: c.enabled == true and not is_nil(c.next_run_at),
             order_by: [asc: c.next_run_at],
             limit: 1,
             select: c.next_run_at
         ) do
      nil -> @fallback_interval_ms
      next_run_at -> max(DateTime.diff(next_run_at, now, :millisecond), @fallback_interval_ms)
    end
  end

  defp initialize_null_next_run_ats do
    Repo.all(from c in CronJob, where: c.enabled == true and is_nil(c.next_run_at))
    |> Enum.each(fn cron ->
      next_run_at = CronJob.compute_next_run_at(cron)
      cron |> CronJob.changeset(%{next_run_at: next_run_at}) |> Repo.update!()
    end)
  end
end
