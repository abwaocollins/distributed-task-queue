defmodule DistributedTaskQueue.Repo.Migrations.AddAttemptedByToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :attempted_by, :string
    end
  end
end
