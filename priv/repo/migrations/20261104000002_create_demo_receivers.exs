defmodule DistributedTaskQueue.Repo.Migrations.CreateDemoReceivers do
  use Ecto.Migration

  def change do
    create table(:demo_receivers) do
      add(:name, :string, null: false)
      add(:online, :boolean, null: false, default: true)
      add(:offline_until, :utc_datetime)
      add(:failure_rate, :float, null: false, default: 0.1)

      timestamps()
    end

    create(unique_index(:demo_receivers, [:name]))
  end
end
