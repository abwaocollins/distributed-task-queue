defmodule DistributedTaskQueue.Repo.Migrations.AddTimezoneToCronJobs do
  use Ecto.Migration

  def change do
    alter table(:cron_jobs) do
      # NULL means UTC, which is how every existing row already behaved.
      add :timezone, :string
    end

    # A timezone only means something for a calendar schedule; interval_seconds
    # is relative to the previous run and has no wall-clock anchor to shift.
    create constraint(:cron_jobs, :timezone_requires_cron_expression,
             check: "timezone IS NULL OR cron_expression IS NOT NULL"
           )
  end
end
