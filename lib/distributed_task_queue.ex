defmodule DistributedTaskQueue do
  @moduledoc false

  alias DistributedTaskQueue.WorkerSupervisor
  alias DistributedTaskQueue.Repo
  alias DistributedTaskQueue.{CronJob, CronScheduler, Job, Queue, QueueCache}
  import Ecto.Query
  require Logger

  def add_job(queue_name, job_attrs) do
    %Job{}
    |> Job.changeset(Map.merge(job_attrs, %{"queue_name" => queue_name}))
    |> Repo.insert()
  end

  def add_queue(attrs) when is_map(attrs) do
    result =
      %Queue{}
      |> Queue.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, queue} -> QueueCache.put(queue)
      _ -> :ok
    end

    result
  end

  def add_queue(queue_name) when is_binary(queue_name) do
    add_queue(%{"name" => queue_name})
  end

  def add_job_error(job_id, error_message) do
    job = Repo.get(Job, job_id)
    if job do
      job
      |> Job.changeset(%{"error_message" => error_message})
      |> Repo.update()
    else
      {:error, "Job not found"}
    end
  end

  def list_jobs, do: Repo.all(Job)

  def get_job(job_id) do
    Repo.one(from j in Job, where: j.id == ^job_id and is_nil(j.deleted_at))
  end

  def list_queues, do: Repo.all(Queue)

  def list_pending_jobs do
    Repo.all(from j in Job, where: j.status == "pending")
  end

  def list_dead_letter_jobs do
    Repo.all(from j in Job, where: j.dead_letter == true, order_by: [desc: j.discarded_at])
  end

  def requeue_dead_letter_job(job_id) do
    job = Repo.get(Job, job_id)

    cond do
      is_nil(job) ->
        {:error, :not_found}

      job.dead_letter != true ->
        {:error, :not_dead_letter}

      true ->
        result =
          job
          |> Job.changeset(%{
            "status" => "pending",
            "dead_letter" => false,
            "attempts" => 0,
            "worker_id" => nil,
            "error_message" => nil,
            "discarded_at" => nil,
            "next_retry_at" => nil,
            "started_at" => nil,
            "completed_at" => nil
          })
          |> Repo.update()

        case result do
          {:ok, updated} ->
            ensure_queue_running(updated.queue_name)
            {:ok, updated}

          other ->
            other
        end
    end
  end

  def requeue_all_dead_letter_jobs do
    count =
      list_dead_letter_jobs()
      |> Enum.reduce(0, fn job, acc ->
        case requeue_dead_letter_job(job.id) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    {:ok, count}
  end

  @doc """
  Start the queue's manager if it isn't already running, so a newly available
  job is actually claimed.

  A `QueueManager` stops itself once its queue drains, and only
  `QueueBootstrapper` starts them at boot — so anything that makes a job
  claimable *after* boot (a requeue, a cron firing) has to call this or the job
  sits `pending` forever.

  Idempotent: an already-running manager returns `{:error, {:already_started, _}}`,
  which we ignore. If the queue row is gone, there is nothing to start.
  """
  def ensure_queue_running(queue_name) do
    case get_queue(queue_name) do
      nil ->
        :ok

      queue ->
        WorkerSupervisor.start_queue(queue_name, queue.max_concurrent_jobs)
        :ok
    end
  end

  def list_jobs_filtered(filters \\ %{}) do
    query = from j in Job, where: is_nil(j.deleted_at)

    query =
      case Map.get(filters, "queue") || Map.get(filters, :queue) do
        nil -> query
        queue -> from j in query, where: j.queue_name == ^queue
      end

    query =
      case Map.get(filters, "status") || Map.get(filters, :status) do
        nil -> query
        status -> from j in query, where: j.status == ^status
      end

    Repo.all(from j in query, order_by: [asc: j.inserted_at])
  end

  def list_upcoming_jobs do
    Repo.all(from j in Job, where: j.scheduled_at > ^DateTime.utc_now())
  end

  def list_jobs_in_queue(queue_name) do
    Repo.all(from j in Job, where: j.queue_name == ^queue_name)
  end

  def list_jobs_for_worker(queue_name, slot) do
    Repo.all(
      from j in Job,
        where: j.queue_name == ^queue_name and j.worker_id == ^slot,
        order_by: [asc: j.inserted_at]
    )
  end

  def get_queue(queue_name), do: Repo.get_by(Queue, name: queue_name)

  # Atomically claim one available job for a worker using a subquery update to avoid races.
  def claim_job(queue_name, worker_id) do
    now = DateTime.utc_now()

    subquery =
      from j in Job,
        where:
          j.queue_name == ^queue_name and is_nil(j.worker_id) and
            ((j.status == "pending" and (is_nil(j.scheduled_at) or j.scheduled_at <= ^now)) or
               (j.status == "retryable" and
                  (is_nil(j.next_retry_at) or j.next_retry_at <= ^now))),
        order_by: [asc: j.inserted_at],
        limit: 1,
        select: j.id

    attempted_by = "#{Node.self()}:#{queue_name}"

    {_count, jobs} =
      Repo.update_all(
        from(j in Job, where: j.id in subquery(subquery), select: j),
        set: [worker_id: worker_id, status: "started", started_at: now, attempted_by: attempted_by]
      )

    case jobs do
      [job] -> {:ok, job}
      _ -> {:error, :no_jobs}
    end
  end

  def update_job_status(job_id, new_status, error_message \\ nil) do
    job = Repo.get(Job, job_id)

    if job do
      extra =
        case new_status do
          "started" ->
            %{"started_at" => DateTime.utc_now()}

          "completed" ->
            %{"completed_at" => DateTime.utc_now()}

          "discarded" ->
            %{"discarded_at" => DateTime.utc_now(), "error_message" => error_message, "dead_letter" => true}

          "retryable" ->
            %{
              "error_message" => error_message || "Job failed",
              "attempts" => job.attempts + 1,
              "next_retry_at" => DateTime.add(DateTime.utc_now(), backoff_seconds(job.attempts), :second),
              "worker_id" => nil
            }

          _ ->
            %{}
        end

      job
      |> Job.changeset(Map.merge(extra, %{"status" => new_status}))
      |> Repo.update()
    else
      {:error, "Job not found"}
    end
  end

  # Exponential backoff: 15 * 2^attempts, capped at 1 hour.
  # attempts=0 → 15s, 1 → 30s, 2 → 60s, 3 → 120s, …, 8+ → 3600s
  defp backoff_seconds(attempts), do: min(15 * Integer.pow(2, attempts), 3_600)

  # Returns milliseconds until the earliest retryable job in the queue becomes claimable,
  # or nil if none exist. Used by QueueManager to avoid shutting down prematurely.
  def next_retryable_delay(queue_name) do
    now = DateTime.utc_now()

    next =
      Repo.one(
        from j in Job,
          where: j.queue_name == ^queue_name and j.status == "retryable" and not is_nil(j.next_retry_at),
          order_by: [asc: j.next_retry_at],
          limit: 1,
          select: j.next_retry_at
      )

    case next do
      nil -> nil
      next_retry_at -> max(DateTime.diff(next_retry_at, now, :millisecond), 0)
    end
  end

  def delete_job(job_id) do
    job = Repo.get(Job, job_id)

    cond do
      is_nil(job) ->
        {:error, :not_found}

      job.status == "started" ->
        {:error, :job_running}

      true ->
        job
        |> Job.changeset(%{"deleted_at" => DateTime.utc_now(), "status" => "deleted"})
        |> Repo.update()
    end
  end

  def hard_delete_job(job_id) do
    job = Repo.get(Job, job_id)

    if job do
      Repo.delete(job)
    else
      {:error, "Job not found"}
    end
  end

  def start_queue(queue_name) do
    case get_queue(queue_name) do
      nil -> {:error, :queue_not_found}
      queue -> WorkerSupervisor.start_queue(queue_name, queue.max_concurrent_jobs)
    end
  end

  def stop_queue(queue_name) do
    case get_queue(queue_name) do
      nil ->
        {:error, :queue_not_found}

      _queue ->
        pending_count =
          from(j in Job, where: j.queue_name == ^queue_name and j.status in ["pending", "retryable"])
          |> Repo.aggregate(:count)

        if pending_count > 0 do
          {:error, {:pending_jobs, pending_count}}
        else
          WorkerSupervisor.stop_queue(queue_name)
        end
    end
  end

  def delete_queue(queue_name) do
    case get_queue(queue_name) do
      nil ->
        {:error, :queue_not_found}

      queue ->
        # Stop the manager first so it cannot claim a job that is about to be deleted.
        WorkerSupervisor.stop_queue(queue_name)

        {:ok, disabled} =
          Repo.transaction(fn ->
            Repo.delete_all(from j in Job, where: j.queue_name == ^queue_name)

            # Cron jobs point at a queue by name, with no FK to cascade. Left
            # enabled they would keep enqueueing into a queue that no longer
            # exists, producing jobs nothing can ever run. Disable rather than
            # delete so the definition survives and can be repointed.
            {count, _} =
              Repo.update_all(
                from(c in CronJob, where: c.queue_name == ^queue_name and c.enabled == true),
                set: [
                  enabled: false,
                  updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
                ]
              )

            Repo.delete!(queue)
            count
          end)

        if disabled > 0 do
          Logger.warning(
            "DistributedTaskQueue: disabled #{disabled} cron job(s) targeting deleted queue #{queue_name}"
          )
        end

        QueueCache.delete(queue_name)
        CronScheduler.reschedule()
        {:ok, queue}
    end
  end

  def pause_queue(queue_name) do
    case get_queue(queue_name) do
      nil ->
        {:error, :queue_not_found}

      queue ->
        result = queue |> Queue.changeset(%{paused: true}) |> Repo.update()

        case result do
          {:ok, updated} -> QueueCache.put(updated)
          _ -> :ok
        end

        result
    end
  end

  def resume_queue(queue_name) do
    case get_queue(queue_name) do
      nil ->
        {:error, :queue_not_found}

      queue ->
        result = queue |> Queue.changeset(%{paused: false}) |> Repo.update()

        case result do
          {:ok, updated} -> QueueCache.put(updated)
          _ -> :ok
        end

        result
    end
  end

  def create_cron_job(attrs) do
    %CronJob{}
    |> CronJob.changeset(attrs)
    |> put_next_run_at()
    |> Repo.insert()
    |> notify_scheduler()
  end

  def list_cron_jobs, do: Repo.all(CronJob)

  def get_cron_job(id), do: Repo.get(CronJob, id)

  def update_cron_job(cron_job, attrs) do
    cron_job
    |> CronJob.changeset(attrs)
    |> put_next_run_at_if_schedule_changed()
    |> Repo.update()
    |> notify_scheduler()
  end

  def delete_cron_job(cron_job), do: cron_job |> Repo.delete() |> notify_scheduler()

  @doc """
  Re-enable a cron job, restarting its schedule from now.

  `next_run_at` is always recomputed: a cron that was disabled for a week has a
  `next_run_at` far in the past, and leaving it there would fire an unintended
  catch-up run the moment it came back.
  """
  def enable_cron_job(cron_job) do
    cron_job
    |> CronJob.changeset(%{enabled: true})
    |> put_next_run_at()
    |> Repo.update()
    |> notify_scheduler()
  end

  def disable_cron_job(cron_job) do
    cron_job
    |> CronJob.changeset(%{enabled: false})
    |> Repo.update()
    |> notify_scheduler()
  end

  # The scheduler sleeps until the next known run, so any write that changes
  # when something is due has to wake it — otherwise a cron due in 10s can wait
  # for a run that is an hour out.
  defp notify_scheduler({:ok, _} = result) do
    CronScheduler.reschedule()
    result
  end

  defp notify_scheduler(result), do: result

  @config_replace_fields [
    :worker_module,
    :queue_name,
    :cron_expression,
    :interval_seconds,
    :timezone,
    :payload,
    :max_attempts,
    :overlap,
    :description,
    :updated_at
  ]

  def upsert_cron_jobs_from_config do
    Application.get_env(:distributed_task_queue, :cron_jobs, [])
    |> Enum.map(&upsert_cron_job_from_config/1)
  end

  defp upsert_cron_job_from_config(attrs) do
    changeset = CronJob.changeset(%CronJob{}, Map.put(attrs, :next_run_at, nil))

    if changeset.valid? do
      existing = Repo.get_by(CronJob, name: Ecto.Changeset.get_field(changeset, :name))

      # Clearing next_run_at on every boot pushes the schedule back each restart —
      # a service that redeploys hourly could keep deferring an hourly cron past
      # its slot forever. Only reset it when the schedule itself actually changed;
      # a nil next_run_at is recomputed by CronScheduler right after this runs.
      replace =
        if schedule_changed?(existing, changeset),
          do: [:next_run_at | @config_replace_fields],
          else: @config_replace_fields

      Repo.insert(changeset, on_conflict: {:replace, replace}, conflict_target: :name)
    else
      Logger.error(
        "DistributedTaskQueue: invalid cron_jobs config entry #{inspect(attrs)}: #{inspect(changeset.errors)}"
      )

      {:error, changeset}
    end
  end

  defp schedule_changed?(nil, _changeset), do: true

  defp schedule_changed?(existing, changeset) do
    Enum.any?([:cron_expression, :interval_seconds, :timezone], fn field ->
      Ecto.Changeset.get_field(changeset, field) != Map.fetch!(existing, field)
    end)
  end

  defp put_next_run_at(changeset) do
    if changeset.valid? do
      next_run_at = changeset |> Ecto.Changeset.apply_changes() |> CronJob.compute_next_run_at()
      Ecto.Changeset.put_change(changeset, :next_run_at, next_run_at)
    else
      changeset
    end
  end

  defp put_next_run_at_if_schedule_changed(changeset) do
    if Ecto.Changeset.changed?(changeset, :cron_expression) or
         Ecto.Changeset.changed?(changeset, :interval_seconds) do
      put_next_run_at(changeset)
    else
      changeset
    end
  end
end
