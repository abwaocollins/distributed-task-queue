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

    test "sets next_run_at to nil on conflict so it gets recomputed" do
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60,
             next_run_at: ~U[2099-01-01 00:00:00Z])
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
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
