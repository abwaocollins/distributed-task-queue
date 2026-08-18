defmodule DistributedTaskQueueTest do
  use ExUnit.Case

  test "application starts" do
    assert :ok == :application.ensure_started(:distributed_task_queue)
  end
end

defmodule DistributedTaskQueue.UpsertCronJobsFromConfigTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{Repo, CronJob}

  @valid_entry %{
    name: "config-test-cron",
    worker_module: "MyApp.TestWorker",
    queue_name: "default",
    payload: %{},
    interval_seconds: 60
  }

  setup do
    on_exit(fn -> Application.delete_env(:distributed_task_queue, :cron_jobs) end)
    :ok
  end

  describe "upsert_cron_jobs_from_config/0" do
    test "inserts a new cron job from config" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.worker_module == "MyApp.TestWorker"
      assert cron.interval_seconds == 60
      assert is_nil(cron.next_run_at)
    end

    test "updates worker_module on conflict (name already exists)" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])
      DistributedTaskQueue.upsert_cron_jobs_from_config()

      updated_entry = Map.put(@valid_entry, :worker_module, "MyApp.UpdatedWorker")
      Application.put_env(:distributed_task_queue, :cron_jobs, [updated_entry])
      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.worker_module == "MyApp.UpdatedWorker"
    end

    test "preserves next_run_at on conflict when the schedule is unchanged" do
      # Boot must not push a pending run back, or a service that restarts more
      # often than its cron interval would never fire it.
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60,
             next_run_at: ~U[2099-01-01 00:00:00Z])
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.next_run_at == ~U[2099-01-01 00:00:00Z]
    end

    test "resets next_run_at on conflict when interval_seconds changes" do
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60,
             next_run_at: ~U[2099-01-01 00:00:00Z])
      Application.put_env(:distributed_task_queue, :cron_jobs,
        [Map.put(@valid_entry, :interval_seconds, 900)])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.interval_seconds == 900
      assert is_nil(cron.next_run_at)
    end

    test "resets next_run_at on conflict when the schedule switches to a cron expression" do
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60,
             next_run_at: ~U[2099-01-01 00:00:00Z])

      entry =
        @valid_entry
        |> Map.delete(:interval_seconds)
        |> Map.put(:cron_expression, "0 9 * * *")

      Application.put_env(:distributed_task_queue, :cron_jobs, [entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.cron_expression == "0 9 * * *"
      assert is_nil(cron.interval_seconds)
      assert is_nil(cron.next_run_at)
    end

    test "preserves enabled flag on conflict" do
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60, enabled: false)
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      refute cron.enabled
    end

    test "does nothing when config is empty" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      assert Repo.aggregate(CronJob, :count) == 0
    end

    test "returns error tuple for invalid config entry, does not raise" do
      bad_entry = %{name: "bad-cron"}
      Application.put_env(:distributed_task_queue, :cron_jobs, [bad_entry])

      results = DistributedTaskQueue.upsert_cron_jobs_from_config()

      assert [{:error, _changeset}] = results
    end
  end
end

defmodule DistributedTaskQueue.QueuePauseTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.QueueCache

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "add_queue writes the queue to QueueCache" do
    {:ok, queue} = DistributedTaskQueue.add_queue(%{"name" => "cache-write-q"})
    assert QueueCache.get("cache-write-q") != nil
    assert QueueCache.get("cache-write-q").name == queue.name
  end

  test "pause_queue sets paused: true in DB and cache" do
    {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => "pausable-q"})
    {:ok, paused} = DistributedTaskQueue.pause_queue("pausable-q")
    assert paused.paused == true
    assert QueueCache.get("pausable-q").paused == true
  end

  test "resume_queue sets paused: false in DB and cache" do
    {:ok, _} = DistributedTaskQueue.add_queue(%{"name" => "resumable-q"})
    {:ok, _} = DistributedTaskQueue.pause_queue("resumable-q")
    {:ok, resumed} = DistributedTaskQueue.resume_queue("resumable-q")
    assert resumed.paused == false
    assert QueueCache.get("resumable-q").paused == false
  end

  test "pause_queue returns error for unknown queue" do
    assert DistributedTaskQueue.pause_queue("ghost-queue") == {:error, :queue_not_found}
  end

  test "resume_queue returns error for unknown queue" do
    assert DistributedTaskQueue.resume_queue("ghost-queue") == {:error, :queue_not_found}
  end
end

defmodule DistributedTaskQueue.DeadLetterTest do
  use DistributedTaskQueue.DataCase, async: true

  test "discarding a job sets dead_letter: true" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, status: "pending", max_attempts: 1)

    {:ok, discarded} = DistributedTaskQueue.update_job_status(job.id, "discarded", "exhausted")

    assert discarded.dead_letter == true
    assert discarded.status == "discarded"
    assert discarded.discarded_at != nil
  end

  test "non-discarded status transitions do not set dead_letter" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, status: "pending")

    {:ok, completed} = DistributedTaskQueue.update_job_status(job.id, "completed")

    assert completed.dead_letter == false
  end

  test "list_dead_letter_jobs returns only dead-lettered jobs" do
    queue = insert(:queue)
    job_a = insert(:job, queue_name: queue.name, max_attempts: 1)
    job_b = insert(:job, queue_name: queue.name, max_attempts: 1)
    _job_c = insert(:job, queue_name: queue.name, max_attempts: 3)

    DistributedTaskQueue.update_job_status(job_a.id, "discarded", "failed")
    DistributedTaskQueue.update_job_status(job_b.id, "discarded", "failed")

    dead = DistributedTaskQueue.list_dead_letter_jobs()
    ids = Enum.map(dead, & &1.id)

    assert job_a.id in ids
    assert job_b.id in ids
  end
end

defmodule DistributedTaskQueue.DeleteQueueTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{QueueCache, WorkerSupervisor}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "delete_queue removes the queue, its jobs, the cache entry, and stops the manager" do
    {:ok, queue} =
      DistributedTaskQueue.add_queue(%{
        "name" => "del-q-#{System.unique_integer([:positive])}",
        "max_concurrent_jobs" => 2
      })

    {:ok, _job} =
      DistributedTaskQueue.add_job(queue.name, %{
        "worker_module" => "DistributedTaskQueue.EmailWorker",
        "payload" => %{}
      })

    {:ok, _pid} = WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)

    assert {:ok, deleted} = DistributedTaskQueue.delete_queue(queue.name)
    assert deleted.name == queue.name

    assert DistributedTaskQueue.get_queue(queue.name) == nil
    assert DistributedTaskQueue.list_jobs_in_queue(queue.name) == []
    assert QueueCache.get(queue.name) == nil
    assert Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name) == []
  end

  test "delete_queue returns error for unknown queue" do
    assert DistributedTaskQueue.delete_queue("ghost-queue") == {:error, :queue_not_found}
  end

  test "delete_queue disables cron jobs that target the deleted queue" do
    {:ok, queue} =
      DistributedTaskQueue.add_queue(%{"name" => "del-cron-q-#{System.unique_integer([:positive])}"})

    targeting = insert(:cron_job, queue_name: queue.name, enabled: true)
    untouched = insert(:cron_job, enabled: true)

    assert {:ok, _} = DistributedTaskQueue.delete_queue(queue.name)

    # Otherwise the scheduler keeps enqueueing into a queue that no longer
    # exists, producing jobs nothing can ever claim.
    refute Repo.get!(DistributedTaskQueue.CronJob, targeting.id).enabled
    assert Repo.get!(DistributedTaskQueue.CronJob, untouched.id).enabled
  end
end

defmodule DistributedTaskQueue.RequeueDeadLetterTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.WorkerSupervisor

  test "requeue_dead_letter_job resets the job to a claimable pending state" do
    queue = insert(:queue, name: "rq-#{System.unique_integer([:positive])}")
    on_exit(fn -> WorkerSupervisor.stop_queue(queue.name) end)

    job =
      insert(:job,
        queue_name: queue.name,
        status: "discarded",
        dead_letter: true,
        worker_id: 1,
        attempts: 3,
        error_message: "boom",
        discarded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

    assert {:ok, requeued} = DistributedTaskQueue.requeue_dead_letter_job(job.id)
    assert requeued.status == "pending"
    assert requeued.dead_letter == false
    assert requeued.attempts == 0
    assert is_nil(requeued.worker_id)
    assert is_nil(requeued.discarded_at)
    assert is_nil(requeued.error_message)

    # The queue's manager was (re)started so the job can be picked up.
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)
  end

  test "ensure_queue_running reports a missing queue instead of silently doing nothing" do
    # Returning :ok here is what let a cron enqueue into a void unnoticed.
    assert DistributedTaskQueue.ensure_queue_running("ghost-queue") == {:error, :queue_not_found}
  end

  test "requeue_dead_letter_job returns error for unknown job" do
    assert DistributedTaskQueue.requeue_dead_letter_job(0) == {:error, :not_found}
  end

  test "requeue_dead_letter_job returns error for a non-dead-letter job" do
    queue = insert(:queue, name: "rq-live-#{System.unique_integer([:positive])}")
    job = insert(:job, queue_name: queue.name, status: "completed", dead_letter: false)

    assert DistributedTaskQueue.requeue_dead_letter_job(job.id) == {:error, :not_dead_letter}
  end

  test "requeue_all_dead_letter_jobs requeues every dead-lettered job" do
    queue = insert(:queue, name: "bulk-rq-#{System.unique_integer([:positive])}")
    on_exit(fn -> WorkerSupervisor.stop_queue(queue.name) end)

    a = insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 1)
    b = insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true, worker_id: 2)
    _live = insert(:job, queue_name: queue.name, status: "pending", dead_letter: false)

    assert {:ok, 2} = DistributedTaskQueue.requeue_all_dead_letter_jobs()
    assert DistributedTaskQueue.get_job(a.id).status == "pending"
    assert DistributedTaskQueue.get_job(b.id).status == "pending"
    assert DistributedTaskQueue.list_dead_letter_jobs() == []
  end
end
