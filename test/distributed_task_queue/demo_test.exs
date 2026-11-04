defmodule DistributedTaskQueue.DemoTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{CronJob, Demo, DemoWorker, Job, Queue, QueueCache, Repo}
  alias DistributedTaskQueue.Demo.OrderWorker
  alias DistributedTaskQueue.Webhooks.Delivery

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  describe "DemoWorker" do
    test "succeeds or fails according to failure_rate" do
      assert :ok = DemoWorker.perform(%{"min_ms" => 0, "max_ms" => 0, "failure_rate" => 0.0})

      assert {:error, _} =
               DemoWorker.perform(%{"min_ms" => 0, "max_ms" => 0, "failure_rate" => 1.0})
    end

    test "fan_out enqueues that many children without the fan-out keys" do
      queue = insert(:queue, name: "demo-fan-#{System.unique_integer([:positive])}")
      # Paused so the children stay where we can count them.
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)

      assert :ok =
               DemoWorker.perform(%{
                 "fan_out" => 3,
                 "fan_out_queue" => queue.name,
                 "failure_rate" => 0.0
               })

      children = Repo.all(from(j in Job, where: j.queue_name == ^queue.name))
      assert length(children) == 3
      assert Enum.all?(children, &(&1.payload == %{"failure_rate" => 0.0}))
      assert Enum.all?(children, &(&1.worker_module == "DistributedTaskQueue.DemoWorker"))
    end
  end

  describe "OrderWorker" do
    test "an order enqueues three webhooks to the three receivers" do
      Demo.seed()
      # Paused so the deliveries stay where we can count them.
      {:ok, _} = DistributedTaskQueue.pause_queue("webhooks")

      assert :ok = OrderWorker.perform(%{})

      jobs = Repo.all(from(j in Job, where: j.queue_name == "webhooks"))
      assert length(jobs) == 3

      urls = jobs |> Enum.map(& &1.payload["url"]) |> Enum.sort()
      assert Enum.map(urls, &Path.basename/1) == ["email", "payments", "warehouse"]

      assert [body] = jobs |> Enum.map(& &1.payload["body"]) |> Enum.uniq() |> Enum.map(&Jason.decode!/1)
      assert body["order_id"] =~ ~r/^ACME-[0-9A-F]{6}$/
      assert is_number(body["total"]) and body["total"] >= 5 and body["total"] <= 250
      assert is_binary(body["customer"])
    end
  end

  describe "seed/0" do
    test "creates the demo queues and Acme crons, and is idempotent" do
      Demo.seed()
      Demo.seed()

      for name <- Demo.queue_names(), do: assert(Repo.get_by(Queue, name: name))
      refute Repo.get_by(Queue, name: "demo-reports")

      assert Repo.aggregate(from(c in CronJob, where: like(c.name, "acme-%")), :count) == 2
    end

    test "seed creates the Acme crons once" do
      Demo.seed()

      orders = Repo.get_by!(CronJob, name: "acme-orders")
      assert orders.interval_seconds == 10
      assert orders.overlap
      assert orders.queue_name == "demo"
      assert orders.worker_module == "DistributedTaskQueue.Demo.OrderWorker"

      report = Repo.get_by!(CronJob, name: "acme-daily-sales-report")
      assert report.interval_seconds == 60
      refute report.overlap
      assert report.queue_name == "webhooks"
      assert report.payload["url"] =~ "/demo/receivers/email"
      assert Jason.decode!(report.payload["body"]) == %{"report" => "daily-sales"}

      Demo.seed()
      assert Repo.aggregate(from(c in CronJob, where: like(c.name, "acme-%")), :count) == 2
    end

    test "seed retires the old demo crons by name" do
      for name <- ["demo-burst", "demo-nightly-report"],
          do: insert(:cron_job, name: name)

      Demo.seed()

      refute Repo.get_by(CronJob, name: "demo-burst")
      refute Repo.get_by(CronJob, name: "demo-nightly-report")
    end

    test "does not overwrite a demo cron edited from the console" do
      Demo.seed()
      cron = Repo.get_by!(CronJob, name: "acme-orders")
      {:ok, _} = DistributedTaskQueue.disable_cron_job(cron)

      Demo.seed()

      refute Repo.get_by!(CronJob, name: "acme-orders").enabled
    end
  end

  describe "prune/0" do
    test "removes old finished demo jobs and nothing else" do
      Demo.seed()
      other = insert(:queue)

      old_done = insert(:job, queue_name: "demo", status: "completed", completed_at: ago(7_200))
      new_done = insert(:job, queue_name: "demo", status: "completed", completed_at: ago(60))

      old_dead =
        insert(:job,
          queue_name: "demo",
          status: "discarded",
          dead_letter: true,
          discarded_at: ago(2 * 86_400)
        )

      foreign =
        insert(:job, queue_name: other.name, status: "completed", completed_at: ago(7_200))

      assert Demo.prune() == 2

      refute Repo.get(Job, old_done.id)
      refute Repo.get(Job, old_dead.id)
      assert Repo.get(Job, new_done.id)
      assert Repo.get(Job, foreign.id)
    end

    test "prune removes old webhook jobs and their deliveries" do
      Demo.seed()
      old = insert(:job, queue_name: "webhooks", status: "completed", completed_at: ago(7_200))
      Repo.insert!(%Delivery{job_id: old.id, number: 1})

      assert Demo.prune() == 1

      refute Repo.get(Job, old.id)
      assert Repo.aggregate(from(d in Delivery, where: d.job_id == ^old.id), :count) == 0
    end
  end
end
