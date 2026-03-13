defmodule DistributedTaskQueue.Repo.Migrations.CreateJobsAndQueues do
  use Ecto.Migration

  def change do
    create table(:queues) do
      add :name, :string, null: false
      add :description, :text
      add :max_concurrent_jobs, :integer, default: 5, null: false

      timestamps()
    end

    create unique_index(:queues, :name)

    create table(:jobs) do
      add :payload, :map, null: false
      add :worker_module, :string, null: false
      add :queue_name, :string, null: false
      add :status, :string, default: "pending"
      add :attempts, :integer, default: 0
      add :max_attempts, :integer, default: 3
      add :error_message, :text
      add :scheduled_at, :utc_datetime
      add :started_at, :utc_datetime
      add :next_retry_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :discarded_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps()
    end
    create index(:jobs, [:queue_name, :status])
    create index(:jobs, [:next_retry_at])
    create index(:jobs, [:status])

  end

end
