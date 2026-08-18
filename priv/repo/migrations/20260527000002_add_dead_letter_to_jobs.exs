defmodule DistributedTaskQueue.Repo.Migrations.AddDeadLetterToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :dead_letter, :boolean, null: false, default: false
    end

    create index(:jobs, [:dead_letter])
  end
end
