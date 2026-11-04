defmodule DistributedTaskQueue.Demo do
  @moduledoc """
  Keeps a public demo alive. Started only when `:demo_mode` is true
  (`DTQ_DEMO_MODE=true`).

  At boot it creates the demo queues and cron jobs if they are missing — it
  never overwrites them, so changes made from the console stick. Every
  `@prune_interval_ms` it deletes old finished jobs from the demo queues, so a
  demo left running for months does not grow the jobs table without bound.
  Nothing outside the demo queues is touched.
  """
  use GenServer
  require Logger

  alias DistributedTaskQueue.{Job, Repo}
  import Ecto.Query

  @worker "DistributedTaskQueue.DemoWorker"
  @prune_interval_ms 10 * 60_000
  @keep_finished_seconds 3_600
  @keep_dead_seconds 24 * 3_600

  @queues [
    %{
      "name" => "demo",
      "description" => "Demo: short jobs, ~15% fail",
      "max_concurrent_jobs" => 4
    },
    %{
      "name" => "demo-reports",
      "description" => "Demo: slow jobs, one at a time",
      "max_concurrent_jobs" => 1
    }
  ]

  @crons [
    %{
      name: "demo-burst",
      description: "Every 20s, fans out 6 short jobs onto `demo`.",
      queue_name: "demo",
      worker_module: @worker,
      interval_seconds: 20,
      overlap: true,
      payload: %{"fan_out" => 6, "failure_rate" => 0.15, "min_ms" => 300, "max_ms" => 2_500}
    },
    %{
      name: "demo-nightly-report",
      description: "Every minute, a slow job; overlap off, so it skips while one runs.",
      queue_name: "demo-reports",
      worker_module: @worker,
      interval_seconds: 60,
      overlap: false,
      payload: %{"failure_rate" => 0.05, "min_ms" => 20_000, "max_ms" => 45_000}
    }
  ]

  def queue_names, do: Enum.map(@queues, & &1["name"])

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Create any missing demo queues and cron jobs. Idempotent."
  def seed do
    Enum.each(@queues, fn attrs ->
      if is_nil(DistributedTaskQueue.get_queue(attrs["name"])),
        do: {:ok, _} = DistributedTaskQueue.add_queue(attrs)
    end)

    Enum.each(@crons, fn attrs ->
      if is_nil(Repo.get_by(DistributedTaskQueue.CronJob, name: attrs.name)),
        do: {:ok, _} = DistributedTaskQueue.create_cron_job(attrs)
    end)
  end

  @doc "Delete old completed and dead-lettered jobs from the demo queues. Returns the count."
  def prune do
    now = DateTime.utc_now()
    finished_before = DateTime.add(now, -@keep_finished_seconds, :second)
    dead_before = DateTime.add(now, -@keep_dead_seconds, :second)

    {count, _} =
      Repo.delete_all(
        from(j in Job,
          where: j.queue_name in ^queue_names(),
          where:
            (j.status == "completed" and j.completed_at < ^finished_before) or
              (j.dead_letter == true and j.discarded_at < ^dead_before)
        )
      )

    count
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :seed}}

  @impl true
  def handle_continue(:seed, state) do
    safely(&seed/0)
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    safely(&prune/0)
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:noreply, state}
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.error("Demo: #{Exception.message(e)}")
  end
end
