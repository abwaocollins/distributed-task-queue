defmodule DistributedTaskQueue.CronSchedulerTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{CronJob, CronScheduler, Job, QueueCache, Repo, WorkerSupervisor}
  import Ecto.Query

  # Firing a cron now starts the target queue's manager, so tear any down again
  # to keep them from outliving the test's sandbox connection.
  setup do
    on_exit(fn ->
      DistributedTaskQueue.WorkerRegistry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(&WorkerSupervisor.stop_queue/1)
    end)

    :ok
  end

  defp due_at_now do
    DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
  end

  describe "fire_due_crons/0" do
    test "creates a job for a due enabled cron" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: true,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      jobs = Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)
      assert length(jobs) == 1
      assert hd(jobs).worker_module == cron.worker_module
      assert hd(jobs).queue_name == cron.queue_name
    end

    test "updates last_run_at and next_run_at after firing" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: true,
        interval_seconds: 120,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      updated = Repo.get!(DistributedTaskQueue.CronJob, cron.id)
      assert not is_nil(updated.last_run_at)
      assert DateTime.diff(updated.next_run_at, DateTime.utc_now(), :second) in 118..122
    end

    test "skips disabled cron jobs" do
      cron = insert(:cron_job,
        enabled: false,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      assert Repo.all(from j in Job, where: j.cron_job_id == ^cron.id) == []
    end

    test "skips future cron jobs" do
      cron = insert(:cron_job,
        enabled: true,
        next_run_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      assert Repo.all(from j in Job, where: j.cron_job_id == ^cron.id) == []
    end

    test "overlap=false: skips fire when a pending job already exists" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: false,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "pending")

      CronScheduler.fire_due_crons()

      assert length(Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)) == 1
    end

    test "overlap=false: skips fire when a started job already exists" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: false,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "started")

      CronScheduler.fire_due_crons()

      assert length(Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)) == 1
    end

    test "overlap=true: fires even when an active job exists" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: true,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "started")

      CronScheduler.fire_due_crons()

      assert length(Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)) == 2
    end
  end

  describe "delivery" do
    test "starts the target queue's manager so the fired job can be claimed" do
      queue = insert(:queue)
      cron = insert(:cron_job, queue_name: queue.name, overlap: true, next_run_at: due_at_now())

      assert Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name) == []

      CronScheduler.fire_due_crons()

      # A QueueManager stops itself when its queue drains, so without this the
      # job would sit pending forever on any queue that had gone quiet.
      assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)
      assert Repo.exists?(from j in Job, where: j.cron_job_id == ^cron.id)
    end
  end

  describe "tick claiming" do
    test "advances next_run_at before enqueueing" do
      cron =
        insert(:cron_job, overlap: true, interval_seconds: 120, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()

      updated = Repo.get!(CronJob, cron.id)
      assert DateTime.compare(updated.next_run_at, DateTime.utc_now()) == :gt
    end

    test "a due cron is claimed exactly once even when polled repeatedly" do
      cron = insert(:cron_job, overlap: true, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()
      CronScheduler.fire_due_crons()
      CronScheduler.fire_due_crons()

      # The conditional UPDATE is what makes it safe to run the scheduler on
      # every node: only the caller whose `next_run_at <= now` still matches
      # owns the tick.
      assert Repo.aggregate(from(j in Job, where: j.cron_job_id == ^cron.id), :count) == 1
    end

    test "concurrent passes over the same due cron produce one job" do
      cron = insert(:cron_job, overlap: true, next_run_at: due_at_now())

      1..5
      |> Task.async_stream(fn _ -> CronScheduler.fire_due_crons() end, max_concurrency: 5)
      |> Stream.run()

      assert Repo.aggregate(from(j in Job, where: j.cron_job_id == ^cron.id), :count) == 1
    end

    test "a disabled cron cannot be claimed even if it is due" do
      cron = insert(:cron_job, enabled: false, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()

      assert Repo.get!(CronJob, cron.id).next_run_at == cron.next_run_at
      assert is_nil(Repo.get!(CronJob, cron.id).last_run_at)
    end
  end

  describe "paused queues" do
    test "does not fire into a paused queue" do
      name = "paused-cron-q-#{System.unique_integer([:positive])}"
      {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => name})
      {:ok, _} = DistributedTaskQueue.pause_queue(name)
      on_exit(fn -> QueueCache.delete(name) end)

      cron = insert(:cron_job, queue_name: name, overlap: true, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()

      assert Repo.all(from j in Job, where: j.cron_job_id == ^cron.id) == []
    end

    test "a skipped tick leaves next_run_at in the past so it fires on resume" do
      name = "resume-cron-q-#{System.unique_integer([:positive])}"
      {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => name})
      {:ok, _} = DistributedTaskQueue.pause_queue(name)
      on_exit(fn -> QueueCache.delete(name) end)

      cron = insert(:cron_job, queue_name: name, overlap: true, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()
      assert Repo.get!(CronJob, cron.id).next_run_at == cron.next_run_at

      {:ok, _} = DistributedTaskQueue.resume_queue(name)
      CronScheduler.fire_due_crons()

      assert Repo.aggregate(from(j in Job, where: j.cron_job_id == ^cron.id), :count) == 1
    end
  end

  describe "missing target queue" do
    # Regression: a cron pointed at a queue with no row enqueued a job nothing
    # could claim, and with overlap: false that one pending job blocked the cron
    # forever. It fired exactly once, then logged `previous_run_active` on every
    # poll for good.
    test "does not enqueue when the target queue does not exist" do
      cron = insert(:cron_job, queue_name: "no-such-queue", next_run_at: due_at_now())

      CronScheduler.fire_due_crons()

      assert Repo.all(from j in Job, where: j.cron_job_id == ^cron.id) == []
    end

    test "leaves the schedule unclaimed so it recovers once the queue is created" do
      cron = insert(:cron_job, queue_name: "late-queue", overlap: true, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()
      assert Repo.get!(CronJob, cron.id).next_run_at == cron.next_run_at

      {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => "late-queue"})
      on_exit(fn -> QueueCache.delete("late-queue") end)

      CronScheduler.fire_due_crons()

      assert Repo.aggregate(from(j in Job, where: j.cron_job_id == ^cron.id), :count) == 1
    end

    test "reports the reason as queue_missing rather than a generic skip" do
      handler_id = "cron-missing-q-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:dtq, :cron, :skipped],
        fn _event, _measurements, meta, _ -> send(test_pid, {:skipped, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      insert(:cron_job, queue_name: "no-such-queue", next_run_at: due_at_now())

      CronScheduler.fire_due_crons()

      assert_receive {:skipped, %{reason: :queue_missing}}
    end

    test "missing_queues/0 lists enabled crons whose queue is absent" do
      orphan = insert(:cron_job, queue_name: "vanished", enabled: true)
      _disabled = insert(:cron_job, queue_name: "also-vanished", enabled: false)
      healthy = insert(:cron_job)

      missing = CronScheduler.missing_queues()

      assert {orphan.name, "vanished"} in missing
      refute {healthy.name, healthy.queue_name} in missing
      # A disabled cron is not going to run anyway; do not add noise for it.
      refute Enum.any?(missing, fn {_, queue} -> queue == "also-vanished" end)
    end
  end

  describe "observability" do
    test "emits a skipped event naming why the tick was dropped" do
      handler_id = "cron-skip-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:dtq, :cron, :skipped],
        fn _event, _measurements, meta, _ -> send(test_pid, {:skipped, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      cron = insert(:cron_job, overlap: false, next_run_at: due_at_now())
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "started")

      CronScheduler.fire_due_crons()

      # Without this a cron blocked by a wedged job stops running silently.
      assert_receive {:skipped, %{reason: :previous_run_active, cron_job_id: id}}
      assert id == cron.id
    end

    test "emits a fired event when a job is enqueued" do
      handler_id = "cron-fire-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:dtq, :cron, :fired],
        fn _event, _measurements, meta, _ -> send(test_pid, {:fired, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      cron = insert(:cron_job, overlap: true, next_run_at: due_at_now())

      CronScheduler.fire_due_crons()

      assert_receive {:fired, %{cron_job_id: id, queue_name: queue_name}}
      assert id == cron.id
      assert queue_name == cron.queue_name
    end
  end

  describe "next_poll_delay_ms/0" do
    test "never sleeps past the ceiling, even when the next run is hours away" do
      insert(:cron_job, next_run_at: DateTime.add(DateTime.utc_now(), 4 * 3600, :second))

      # Otherwise a cron created during that sleep would not fire for hours.
      assert CronScheduler.next_poll_delay_ms() <= 60_000
    end

    test "never sleeps less than the floor for an overdue cron" do
      insert(:cron_job, next_run_at: due_at_now())

      assert CronScheduler.next_poll_delay_ms() >= 1_000
    end

    test "ignores disabled crons when picking the next wake-up" do
      insert(:cron_job, enabled: false, next_run_at: due_at_now())

      assert CronScheduler.next_poll_delay_ms() == 5_000
    end
  end

  describe "start_link/1" do
    test "starts without error" do
      # CronScheduler is started in the application supervision tree,
      # so we expect it to be already running
      case start_supervised(CronScheduler) do
        {:ok, _pid} -> assert true
        {:error, {:already_started, _pid}} -> assert true
      end
    end

    test "upsert_cron_jobs_from_config/0 seeds cron jobs from application config" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [
        %{
          name: "scheduler-init-test",
          worker_module: "MyApp.TestWorker",
          queue_name: "default",
          payload: %{},
          interval_seconds: 300
        }
      ])

      on_exit(fn -> Application.delete_env(:distributed_task_queue, :cron_jobs) end)

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(DistributedTaskQueue.CronJob, name: "scheduler-init-test")
      assert cron != nil
      assert cron.interval_seconds == 300
    end
  end
end
