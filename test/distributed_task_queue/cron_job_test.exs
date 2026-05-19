defmodule DistributedTaskQueue.CronJobTest do
  use DistributedTaskQueue.DataCase, async: true

  alias DistributedTaskQueue.CronJob

  @valid_interval_attrs %{
    name: "send-digest",
    worker_module: "DistributedTaskQueue.EmailWorker",
    queue_name: "emails",
    payload: %{"type" => "digest"},
    interval_seconds: 300
  }

  @valid_cron_attrs %{
    name: "send-digest",
    worker_module: "DistributedTaskQueue.EmailWorker",
    queue_name: "emails",
    payload: %{"type" => "digest"},
    cron_expression: "0 9 * * 1"
  }

  describe "changeset/2 with interval_seconds" do
    test "valid attrs produce a valid changeset" do
      cs = CronJob.changeset(%CronJob{}, @valid_interval_attrs)
      assert cs.valid?
    end

    test "interval_seconds must be positive" do
      cs = CronJob.changeset(%CronJob{}, Map.put(@valid_interval_attrs, :interval_seconds, 0))
      refute cs.valid?
      assert errors_on(cs).interval_seconds != []
    end
  end

  describe "changeset/2 with cron_expression" do
    test "valid cron expression produces a valid changeset" do
      cs = CronJob.changeset(%CronJob{}, @valid_cron_attrs)
      assert cs.valid?
    end

    test "invalid cron expression format is rejected" do
      cs = CronJob.changeset(%CronJob{}, Map.put(@valid_cron_attrs, :cron_expression, "not-a-cron"))
      refute cs.valid?
      assert "is not a valid cron expression" in errors_on(cs).cron_expression
    end
  end

  describe "changeset/2 schedule mutual exclusion" do
    test "both schedule fields set is invalid" do
      attrs = Map.merge(@valid_interval_attrs, %{cron_expression: "* * * * *"})
      cs = CronJob.changeset(%CronJob{}, attrs)
      refute cs.valid?
      assert "only one of cron_expression or interval_seconds may be set" in errors_on(cs).cron_expression
    end

    test "neither schedule field set is invalid" do
      attrs = Map.drop(@valid_interval_attrs, [:interval_seconds])
      cs = CronJob.changeset(%CronJob{}, attrs)
      refute cs.valid?
      assert "either cron_expression or interval_seconds must be set" in errors_on(cs).cron_expression
    end
  end

  describe "changeset/2 required fields" do
    test "name is required" do
      cs = CronJob.changeset(%CronJob{}, Map.delete(@valid_interval_attrs, :name))
      refute cs.valid?
      assert errors_on(cs).name != []
    end

    test "worker_module is required" do
      cs = CronJob.changeset(%CronJob{}, Map.delete(@valid_interval_attrs, :worker_module))
      refute cs.valid?
      assert errors_on(cs).worker_module != []
    end

    test "queue_name is required" do
      cs = CronJob.changeset(%CronJob{}, Map.delete(@valid_interval_attrs, :queue_name))
      refute cs.valid?
      assert errors_on(cs).queue_name != []
    end
  end

  describe "compute_next_run_at/1" do
    test "interval: next_run_at is now + interval_seconds" do
      cron = %CronJob{interval_seconds: 300}
      before = DateTime.utc_now()
      result = CronJob.compute_next_run_at(cron)
      assert DateTime.diff(result, before, :second) in 299..301
    end

    test "cron expression: next_run_at is in the future" do
      cron = %CronJob{cron_expression: "* * * * *"}
      result = CronJob.compute_next_run_at(cron)
      assert DateTime.compare(result, DateTime.utc_now()) == :gt
    end
  end

  describe "Job changeset accepts cron_job_id" do
    test "cron_job_id is castable" do
      attrs = %{
        queue_name: "emails",
        worker_module: "DistributedTaskQueue.EmailWorker",
        payload: %{},
        cron_job_id: 42
      }
      cs = DistributedTaskQueue.Job.changeset(%DistributedTaskQueue.Job{}, attrs)
      assert Ecto.Changeset.get_change(cs, :cron_job_id) == 42
    end
  end
end
