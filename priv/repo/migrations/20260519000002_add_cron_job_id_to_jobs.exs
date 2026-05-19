defmodule DistributedTaskQueue.Repo.Migrations.AddCronJobIdToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :cron_job_id, references(:cron_jobs, on_delete: :nilify_all)
    end

    create index(:jobs, [:cron_job_id])
  end
end
