defmodule DistributedTaskQueue.Reaper do
  @moduledoc """
  Rescues orphaned jobs: rows left in `started` whose worker is gone, because
  the node died or the worker was killed before it could record a result.
  Nothing else ever moves such a row, so without this it sits in `started`
  forever and, for an `overlap: false` cron, blocks every later run.

  Two rules, both standard for Postgres-backed queues:

    * **Stale** — `started` longer than `rescue_after_seconds` (default one
      hour), checked every `interval_ms`. This is the only signal for a node
      that died and never came back. A job that legitimately runs longer than
      the limit will be run a second time, so set the limit above your slowest
      job.

    * **Own node at boot** — on start, any job this node had marked `started`
      cannot still be running, since this node just started. Only on a named
      (distributed) node: every unnamed node is `nonode@nohost`, so two of them
      sharing a database would rescue each other's running jobs.

  A rescued job is treated like a failed attempt: back to `retryable` with
  backoff, or `discarded` (dead letter) if it was on its last attempt.

  Jobs this node's manager is actually running are never rescued, however old.
  Rows are locked `FOR UPDATE SKIP LOCKED`, so a reaper on every node is safe.
  """
  use GenServer

  alias DistributedTaskQueue.{Job, QueueManager, Repo}
  import Ecto.Query
  require Logger

  @default_rescue_after_seconds 3_600
  @default_interval_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Rescue jobs `started` more than `rescue_after_seconds` ago. Returns `{:ok, count}`."
  def rescue_stale(rescue_after_seconds \\ rescue_after_seconds()) do
    cutoff = DateTime.add(DateTime.utc_now(), -rescue_after_seconds, :second)

    rescue_where(
      dynamic([j], is_nil(j.started_at) or j.started_at < ^cutoff),
      :stale,
      "orphaned: still started after #{rescue_after_seconds}s"
    )
  end

  @doc "Rescue jobs this node had marked `started`. Returns `{:ok, count}`."
  def rescue_own_node do
    prefix = "#{Node.self()}:%"

    rescue_where(
      dynamic([j], like(j.attempted_by, ^prefix)),
      :node_restarted,
      "orphaned: node #{Node.self()} restarted while it was running"
    )
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :boot}}

  @impl true
  def handle_continue(:boot, state) do
    if Node.alive?(), do: safely(&rescue_own_node/0)
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_info(:rescue, state) do
    safely(&rescue_stale/0)
    schedule()
    {:noreply, state}
  end

  defp rescue_where(condition, reason, message) do
    {:ok, rescued} =
      Repo.transaction(fn ->
        from(j in Job,
          where: j.status == "started",
          where: ^condition,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()
        # Asked only after the rows are locked, so a job claimed after we looked
        # is either in this list or in the manager's — never in neither.
        |> Enum.reject(&running_here?/1)
        |> Enum.map(&rescue_job(&1, message))
      end)

    Enum.each(rescued, &report(&1, reason))

    rescued
    |> Enum.filter(&(&1.status == "retryable"))
    |> Enum.uniq_by(& &1.queue_name)
    |> Enum.each(&DistributedTaskQueue.ensure_queue_running(&1.queue_name))

    {:ok, length(rescued)}
  end

  defp running_here?(job) do
    job.attempted_by == "#{Node.self()}:#{job.queue_name}" and
      MapSet.member?(QueueManager.running_job_ids(job.queue_name), job.id)
  end

  # Same transition as a worker failure, so attempts, backoff and dead-lettering
  # behave exactly as if the job had returned an error.
  defp rescue_job(job, message) do
    status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
    {:ok, updated} = DistributedTaskQueue.update_job_status(job.id, status, message)
    updated
  end

  defp report(job, reason) do
    Logger.warning(
      "Reaper: rescued orphaned job #{job.id} on #{job.queue_name} (#{reason}) -> #{job.status}"
    )

    :telemetry.execute([:dtq, :job, :rescued], %{count: 1}, %{
      job_id: job.id,
      queue_name: job.queue_name,
      worker_module: job.worker_module,
      reason: reason
    })
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.error("Reaper: rescue failed: #{Exception.message(e)}")
  end

  defp schedule, do: Process.send_after(self(), :rescue, interval_ms())

  defp rescue_after_seconds,
    do: config(:rescue_after_seconds, @default_rescue_after_seconds)

  defp interval_ms, do: config(:interval_ms, @default_interval_ms)

  defp config(key, default),
    do: :distributed_task_queue |> Application.get_env(:reaper, []) |> Keyword.get(key, default)
end
