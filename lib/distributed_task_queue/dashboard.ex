defmodule DistributedTaskQueue.Dashboard do
  @moduledoc """
  Read model for the web console. Every list is bounded or paginated, and the
  per-queue numbers come from a single grouped count rather than a query per
  queue.
  """

  import Ecto.Query

  alias DistributedTaskQueue.{CronJob, CronScheduler, Job, Queue, Repo, Worker}

  @page_size 25

  @statuses ~w(pending started retryable completed discarded)

  def page_size, do: @page_size
  def statuses, do: @statuses

  ## Totals and queues

  def totals do
    Enum.reduce(job_counts(), empty_totals(), fn
      {{_q, _status, true}, n}, acc -> Map.update!(acc, :dead, &(&1 + n))
      {{_q, "pending", _}, n}, acc -> Map.update!(acc, :pending, &(&1 + n))
      {{_q, "retryable", _}, n}, acc -> Map.update!(acc, :retryable, &(&1 + n))
      {{_q, "started", _}, n}, acc -> Map.update!(acc, :running, &(&1 + n))
      {{_q, "completed", _}, n}, acc -> Map.update!(acc, :completed, &(&1 + n))
      _, acc -> acc
    end)
  end

  defp empty_totals, do: %{pending: 0, retryable: 0, running: 0, completed: 0, dead: 0}

  def dead_count do
    Repo.aggregate(
      from(j in Job, where: j.dead_letter == true and is_nil(j.deleted_at)),
      :count
    )
  end

  def queue_summaries do
    counts = job_counts()

    Repo.all(from(q in Queue, order_by: q.name))
    |> Enum.map(fn queue ->
      count = fn status -> Map.get(counts, {queue.name, status, false}, 0) end

      %{
        queue: queue,
        name: queue.name,
        paused: queue.paused,
        concurrency: queue.max_concurrent_jobs,
        manager_running: manager_running?(queue.name),
        pending: count.("pending"),
        retryable: count.("retryable"),
        running: count.("started"),
        completed: count.("completed"),
        dead: dead_for(counts, queue.name)
      }
    end)
  end

  def queue_names, do: Repo.all(from(q in Queue, order_by: q.name, select: q.name))

  # {queue_name, status, dead_letter} => count, for every non-deleted job.
  defp job_counts do
    Repo.all(
      from(j in Job,
        where: is_nil(j.deleted_at),
        group_by: [j.queue_name, j.status, j.dead_letter],
        select: {{j.queue_name, j.status, j.dead_letter}, count(j.id)}
      )
    )
    |> Map.new()
  end

  defp dead_for(counts, queue_name) do
    for {{^queue_name, _status, true}, n} <- counts, reduce: 0, do: (acc -> acc + n)
  end

  # A QueueManager is registered locally, so this reports this node only. It
  # stops itself once its queue drains, so "not running" on an empty queue is
  # the normal idle state, not a fault.
  defp manager_running?(queue_name) do
    Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue_name) != []
  end

  ## Jobs

  @doc """
  One page of jobs matching `filters`, newest activity first.

  Filters (all optional, string keys as they arrive from the URL):
  `"queue"`, `"status"` (one of `statuses/0`, or `"dead"` for the dead-letter
  queue), `"errors"` (`"true"` for jobs with an error message) and `"q"` (a job
  id, or text matched against the worker module and error message).
  """
  def list_jobs(filters, page \\ 1) do
    filters
    |> jobs_query()
    |> order_by([j], desc: j.updated_at, desc: j.id)
    |> limit(@page_size)
    |> offset(^((max(page, 1) - 1) * @page_size))
    |> Repo.all()
  end

  def count_jobs(filters), do: filters |> jobs_query() |> Repo.aggregate(:count)

  @doc "Every job matching `filters`, unpaginated. For bulk actions."
  def list_jobs_all(filters), do: filters |> jobs_query() |> Repo.all()

  defp jobs_query(filters) do
    Enum.reduce(filters, from(j in Job, where: is_nil(j.deleted_at)), &filter/2)
  end

  defp filter({_key, ""}, query), do: query
  defp filter({_key, nil}, query), do: query
  defp filter({"queue", queue}, query), do: where(query, [j], j.queue_name == ^queue)
  defp filter({"status", "dead"}, query), do: where(query, [j], j.dead_letter == true)

  defp filter({"status", status}, query) when status in @statuses,
    do: where(query, [j], j.status == ^status and j.dead_letter == false)

  defp filter({"errors", "true"}, query), do: where(query, [j], not is_nil(j.error_message))

  defp filter({"q", text}, query) do
    case Integer.parse(String.trim(text)) do
      {id, ""} ->
        where(query, [j], j.id == ^id)

      _ ->
        like = "%" <> escape_like(String.trim(text)) <> "%"
        where(query, [j], ilike(j.worker_module, ^like) or ilike(j.error_message, ^like))
    end
  end

  defp filter(_unknown, query), do: query

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  def get_job(id), do: Repo.one(from(j in Job, where: j.id == ^id and is_nil(j.deleted_at)))

  def recent_failures(limit \\ 6) do
    Repo.all(
      from(j in Job,
        where: is_nil(j.deleted_at) and not is_nil(j.error_message),
        where: j.status in ["retryable", "discarded"],
        order_by: [desc: j.updated_at, desc: j.id],
        limit: ^limit
      )
    )
  end

  ## Cron

  def cron_jobs do
    Repo.all(
      from(c in CronJob,
        order_by: [desc: c.enabled, asc_nulls_last: c.next_run_at, asc: c.name]
      )
    )
  end

  def upcoming_crons(limit \\ 5) do
    Repo.all(
      from(c in CronJob,
        where: c.enabled == true and not is_nil(c.next_run_at),
        order_by: [asc: c.next_run_at],
        limit: ^limit
      )
    )
  end

  @doc """
  Names of cron jobs declared in config. These are upserted from config at
  every boot, so edits made in the console to their config fields do not
  survive a restart.
  """
  def config_cron_names do
    :distributed_task_queue
    |> Application.get_env(:cron_jobs, [])
    |> Enum.map(&to_string(&1[:name] || &1["name"]))
    |> MapSet.new()
  end

  @doc "Enabled crons whose target queue does not exist, as `{cron_name, queue_name}`."
  def crons_missing_queue, do: CronScheduler.missing_queues()

  ## Workers

  @doc """
  Worker modules this node can run, for form suggestions. Only modules that
  pass the same `Worker.resolve/1` check a job is dispatched through.
  """
  def known_workers do
    (Application.spec(:distributed_task_queue, :modules) || [])
    |> Enum.map(&inspect/1)
    |> Enum.filter(&match?({:ok, _}, Worker.resolve(&1)))
    |> Enum.sort()
  end
end
