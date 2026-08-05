defmodule DistributedTaskQueue.CronScheduler do
  use GenServer

  alias DistributedTaskQueue.{CronJob, Job, QueueCache, Repo}
  import Ecto.Query
  require Logger

  # Used when nothing is scheduled at all.
  @idle_poll_ms 5_000
  # Never sleep longer than this. Without a ceiling a cron created while we are
  # sleeping would not fire until the next *already known* run came due, which
  # could be hours away.
  @max_poll_ms 60_000
  # Never sleep less than this, so an overdue-but-blocked cron cannot spin.
  @min_poll_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ask the running scheduler to recompute its next wake-up.

  Call this after any write that changes when a cron is next due. It is a no-op
  when the scheduler is not running, so callers do not need to care (tests, or
  a node that does not run the scheduler).
  """
  def reschedule do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reschedule)
    end
  end

  def fire_due_crons do
    now = DateTime.utc_now()

    Repo.all(
      from c in CronJob,
        where: c.enabled == true and not is_nil(c.next_run_at) and c.next_run_at <= ^now
    )
    |> Enum.each(fn cron ->
      try do
        maybe_fire(cron)
      rescue
        # One broken cron must not stop the rest of this tick.
        e ->
          Logger.error(
            "CronScheduler: cron #{cron.id} (#{cron.name}) raised while firing: #{Exception.message(e)}"
          )
      end
    end)
  end

  @impl true
  def init(_opts) do
    {:ok, %{timer: nil}, {:continue, :seed_and_init}}
  end

  @impl true
  def handle_continue(:seed_and_init, state) do
    try do
      DistributedTaskQueue.upsert_cron_jobs_from_config()
      initialize_null_next_run_ats()
    rescue
      e ->
        Logger.error("CronScheduler: seed_and_init failed: #{Exception.message(e)}")
    end

    {:noreply, reschedule_timer(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    fire_due_crons()
    {:noreply, reschedule_timer(state)}
  end

  @impl true
  def handle_cast(:reschedule, state) do
    {:noreply, reschedule_timer(state)}
  end

  defp maybe_fire(cron) do
    cond do
      queue_paused?(cron.queue_name) ->
        skip(cron, :queue_paused)

      not cron.overlap and not no_active_jobs?(cron.id) ->
        skip(cron, :previous_run_active)

      true ->
        case claim_tick(cron) do
          :ok -> enqueue(cron)
          :already_claimed -> :ok
        end
    end
  end

  # Advance the schedule with a conditional UPDATE *before* enqueueing.
  #
  # Postgres serialises the row write, so when several nodes poll the same due
  # cron exactly one of them gets a row back and owns this tick — every other
  # node's `next_run_at <= now` no longer matches. This is what makes the
  # scheduler safe to run on every node without leader election.
  #
  # Advancing first also means a cron whose enqueue fails backs off to its
  # normal schedule instead of retrying on every poll. The trade-off is
  # at-most-once: a crash between this update and the insert below drops one
  # tick rather than duplicating it.
  defp claim_tick(cron) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    next_run_at = CronJob.compute_next_run_at(cron)

    {count, _} =
      Repo.update_all(
        from(c in CronJob,
          where: c.id == ^cron.id and c.enabled == true and c.next_run_at <= ^now
        ),
        set: [
          last_run_at: now,
          next_run_at: next_run_at,
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      )

    if count == 1, do: :ok, else: :already_claimed
  rescue
    e ->
      Logger.error(
        "CronScheduler: failed to advance schedule for cron #{cron.id} (#{cron.name}): #{Exception.message(e)}"
      )

      :already_claimed
  end

  defp enqueue(cron) do
    case DistributedTaskQueue.add_job(cron.queue_name, %{
           "worker_module" => cron.worker_module,
           "payload" => cron.payload,
           "max_attempts" => cron.max_attempts,
           "cron_job_id" => cron.id
         }) do
      {:ok, job} ->
        # A QueueManager shuts itself down once its queue goes idle, and only
        # QueueBootstrapper restarts them (at boot). Without this, a cron firing
        # into a quiet queue would insert a job that nothing ever claims.
        DistributedTaskQueue.ensure_queue_running(cron.queue_name)

        :telemetry.execute([:dtq, :cron, :fired], %{count: 1}, %{
          cron_job_id: cron.id,
          cron_name: cron.name,
          queue_name: cron.queue_name,
          job_id: job.id
        })

        :ok

      {:error, reason} ->
        Logger.error(
          "CronScheduler: failed to enqueue job for cron #{cron.id} (#{cron.name}): #{inspect(reason)}"
        )

        :telemetry.execute([:dtq, :cron, :failed], %{count: 1}, %{
          cron_job_id: cron.id,
          cron_name: cron.name,
          queue_name: cron.queue_name
        })

        :error
    end
  end

  # A skipped tick deliberately leaves next_run_at in the past so the cron fires
  # as soon as the blocker clears, rather than waiting for its next slot.
  defp skip(cron, reason) do
    Logger.info("CronScheduler: skipped cron #{cron.id} (#{cron.name}): #{reason}")

    :telemetry.execute([:dtq, :cron, :skipped], %{count: 1}, %{
      cron_job_id: cron.id,
      cron_name: cron.name,
      queue_name: cron.queue_name,
      reason: reason
    })

    :ok
  end

  defp queue_paused?(queue_name) do
    case QueueCache.get(queue_name) do
      %{paused: true} -> true
      _ -> false
    end
  end

  defp no_active_jobs?(cron_id) do
    not Repo.exists?(
      from j in Job,
        where: j.cron_job_id == ^cron_id and j.status in ["pending", "started"]
    )
  end

  defp reschedule_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    delay =
      try do
        next_poll_delay_ms()
      rescue
        e ->
          Logger.error("CronScheduler: failed to compute poll delay: #{Exception.message(e)}")
          @idle_poll_ms
      end

    %{state | timer: Process.send_after(self(), :poll, delay)}
  end

  @doc """
  How long to sleep before the next poll, in milliseconds.

  Clamped to `#{@min_poll_ms}..#{@max_poll_ms}`ms: the ceiling keeps a cron
  created mid-sleep from waiting on a run that is hours away, and the floor
  keeps an overdue-but-blocked cron from spinning.
  """
  def next_poll_delay_ms do
    now = DateTime.utc_now()

    case Repo.one(
           from c in CronJob,
             where: c.enabled == true and not is_nil(c.next_run_at),
             order_by: [asc: c.next_run_at],
             limit: 1,
             select: c.next_run_at
         ) do
      nil ->
        @idle_poll_ms

      next_run_at ->
        DateTime.diff(next_run_at, now, :millisecond)
        |> max(@min_poll_ms)
        |> min(@max_poll_ms)
    end
  end

  defp initialize_null_next_run_ats do
    Repo.all(from c in CronJob, where: c.enabled == true and is_nil(c.next_run_at))
    |> Enum.each(fn cron ->
      try do
        next_run_at = CronJob.compute_next_run_at(cron)
        cron |> CronJob.changeset(%{next_run_at: next_run_at}) |> Repo.update!()
      rescue
        # A single unschedulable row must not stop the others from booting.
        e ->
          Logger.error(
            "CronScheduler: could not compute next_run_at for cron #{cron.id} (#{cron.name}): #{Exception.message(e)}"
          )
      end
    end)
  end
end
