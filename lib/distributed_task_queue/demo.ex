defmodule DistributedTaskQueue.Demo do
  @moduledoc """
  Keeps a public demo alive. Started only when `:demo_mode` is true
  (`DTQ_DEMO_MODE=true`).

  The story is an "Acme Store": a cron places an order every 10 seconds and
  each order fans out into three webhooks (payments, email, warehouse), plus a
  scheduled sales-report webhook.

  At boot it creates the demo queues and cron jobs if they are missing — it
  never overwrites them, so changes made from the console stick. Every
  `@prune_interval_ms` it deletes old finished jobs from the demo and webhooks queues, so a
  demo left running for months does not grow the jobs table without bound.
  Nothing outside those queues is touched.
  """
  use GenServer
  require Logger

  alias DistributedTaskQueue.{CronJob, Job, Repo, Webhooks}
  alias DistributedTaskQueue.Demo.Receivers
  alias DistributedTaskQueue.Webhooks.Target
  import Ecto.Query

  @prune_interval_ms 10 * 60_000
  @keep_finished_seconds 3_600
  @keep_dead_seconds 24 * 3_600

  # The webhooks queue is created by `Webhooks.ensure_queue/0`; pruning covers
  # it because the order pipeline fills it with deliveries.
  @queues [
    %{
      "name" => "demo",
      "description" => "Demo: Acme Store places its orders here",
      "max_concurrent_jobs" => 4
    }
  ]

  @retired_crons ["demo-burst", "demo-nightly-report"]

  defp crons do
    [
      %{
        "name" => "acme-orders",
        "description" => "Acme Store places an order every 10 seconds",
        "queue_name" => "demo",
        "worker_module" => "DistributedTaskQueue.Demo.OrderWorker",
        "interval_seconds" => 10,
        "overlap" => true,
        "payload" => %{}
      },
      Webhooks.cron_attrs(%{
        "name" => "acme-daily-sales-report",
        "description" => "Daily sales report (every minute in the demo)",
        "queue_name" => "webhooks",
        "interval_seconds" => 60,
        "overlap" => false,
        "webhook" => %{
          "url" => Target.demo_receiver_url("email"),
          "method" => "POST",
          "body" => %{"report" => "daily-sales"}
        }
      })
    ]
  end

  def queue_names, do: Enum.map(@queues, & &1["name"]) ++ ["webhooks"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Create any missing demo queues and cron jobs. Idempotent."
  def seed do
    Webhooks.ensure_queue()
    Receivers.ensure_all()

    # The old demo story is replaced; remove its crons from existing databases.
    Repo.delete_all(from(c in CronJob, where: c.name in ^@retired_crons))

    Enum.each(@queues, fn attrs ->
      if is_nil(DistributedTaskQueue.get_queue(attrs["name"])),
        do: {:ok, _} = DistributedTaskQueue.add_queue(attrs)
    end)

    Enum.each(crons(), fn attrs ->
      if is_nil(Repo.get_by(CronJob, name: attrs["name"])),
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
