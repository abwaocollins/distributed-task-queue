defmodule DistributedTaskQueue.Repo do
  use Ecto.Repo,
    otp_app: :distributed_task_queue,
    adapter: Ecto.Adapters.Postgres
end
