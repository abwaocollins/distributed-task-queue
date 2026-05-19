defmodule DistributedTaskQueue.Factory do
  use ExMachina.Ecto, repo: DistributedTaskQueue.Repo

  def queue_factory do
    %DistributedTaskQueue.Queue{
      name: sequence(:name, &"queue-#{&1}"),
      description: "Test queue",
      max_concurrent_jobs: 3
    }
  end

  def job_factory do
    queue = insert(:queue)
    %DistributedTaskQueue.Job{
      queue_name: queue.name,
      worker_module: "DistributedTaskQueue.EmailWorker",
      payload: %{"to" => "test@example.com"},
      status: "pending",
      max_attempts: 3
    }
  end

  def cron_job_factory do
    queue = insert(:queue)
    %DistributedTaskQueue.CronJob{
      name: sequence(:name, &"cron-job-#{&1}"),
      worker_module: "DistributedTaskQueue.EmailWorker",
      queue_name: queue.name,
      payload: %{"to" => "test@example.com"},
      interval_seconds: 300,
      overlap: false,
      enabled: true,
      next_run_at: DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:second)
    }
  end
end
