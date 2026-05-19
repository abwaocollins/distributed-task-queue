defmodule DistributedTaskQueue.CronSchedulerTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{CronScheduler, Repo, Job}
  import Ecto.Query

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

  describe "start_link/1" do
    test "starts without error" do
      assert {:ok, _pid} = start_supervised(CronScheduler)
    end
  end
end
