defmodule DistributedTaskQueue.DemoTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{CronJob, Demo, DemoWorker, Job, Queue, QueueCache, Repo}

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

  describe "seed/0" do
    test "creates the demo queues and crons, and is idempotent" do
      Demo.seed()
      Demo.seed()

      for name <- Demo.queue_names(), do: assert(Repo.get_by(Queue, name: name))

      assert Repo.aggregate(from(c in CronJob, where: like(c.name, "demo-%")), :count) == 2
    end

    test "does not overwrite a demo cron edited from the console" do
      Demo.seed()
      cron = Repo.get_by!(CronJob, name: "demo-burst")
      {:ok, _} = DistributedTaskQueue.disable_cron_job(cron)

      Demo.seed()

      refute Repo.get_by!(CronJob, name: "demo-burst").enabled
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
  end
end
