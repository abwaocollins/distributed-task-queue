defmodule DistributedTaskQueue.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries) do
      add(:job_id, references(:jobs, on_delete: :delete_all), null: false)
      add(:number, :integer, null: false)
      add(:method, :string)
      add(:url, :text)
      add(:status_code, :integer)
      add(:duration_ms, :integer)
      add(:response_body, :text)
      add(:error, :text)

      add(:inserted_at, :utc_datetime, null: false)
    end

    # The unique index is the backstop for delivery numbering.
    create(unique_index(:webhook_deliveries, [:job_id, :number]))
  end
end
