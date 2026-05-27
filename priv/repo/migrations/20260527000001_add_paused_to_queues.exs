defmodule DistributedTaskQueue.Repo.Migrations.AddPausedToQueues do
  use Ecto.Migration

  def change do
    alter table(:queues) do
      add :paused, :boolean, null: false, default: false
    end
  end
end
