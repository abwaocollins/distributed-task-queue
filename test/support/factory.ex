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
    %DistributedTaskQueue.Job{
      queue_name: sequence(:queue_name, &"queue-#{&1}"),
      worker_module: "DistributedTaskQueue.EmailWorker",
      payload: %{"to" => "test@example.com"},
      status: "pending",
      max_attempts: 3
    }
  end
end
