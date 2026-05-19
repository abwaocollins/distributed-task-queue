defmodule DistributedTaskQueue.Repo.Migrations.CreateCronJobs do
  use Ecto.Migration

  def change do
    create table(:cron_jobs) do
      add :name, :string, null: false
      add :description, :text
      add :worker_module, :string, null: false
      add :queue_name, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :max_attempts, :integer, null: false, default: 3
      add :cron_expression, :string
      add :interval_seconds, :integer
      add :overlap, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime

      timestamps()
    end

    create unique_index(:cron_jobs, [:name])
    create index(:cron_jobs, [:next_run_at, :enabled])

    create constraint(:cron_jobs, :schedule_xor,
      check: "num_nonnulls(cron_expression, interval_seconds) = 1"
    )
  end
end
