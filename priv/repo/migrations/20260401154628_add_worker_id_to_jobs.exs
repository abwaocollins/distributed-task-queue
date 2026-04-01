defmodule DistributedTaskQueue.Repo.Migrations.AddWorkerIdToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :worker_id, :integer
    end

    create index(:jobs, [:worker_id])
  end
end
