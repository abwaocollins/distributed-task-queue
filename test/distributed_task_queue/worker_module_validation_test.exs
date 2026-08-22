defmodule DistributedTaskQueue.WorkerModuleValidationTest do
  @moduledoc """
  Insert-time validation of `worker_module`.

  This is deliberately a *format* check, not an existence check: in a
  distributed deployment the node enqueueing a job need not have the worker
  module loaded (a thin API tier enqueues, worker nodes execute). Requiring the
  module to exist here would break that topology. Existence and behaviour are
  enforced at dispatch instead — see `WorkerDispatchSecurityTest`.
  """
  use DistributedTaskQueue.DataCase, async: true

  alias DistributedTaskQueue.{CronJob, Job}

  @garbage [
    "../../etc/passwd",
    "erlang:halt",
    "lowercase_module",
    "Has Spaces",
    "Trailing.",
    ""
  ]

  describe "Job.changeset/2" do
    defp job_attrs(worker_module) do
      %{payload: %{}, queue_name: "q", worker_module: worker_module}
    end

    test "accepts a well-formed module name" do
      cs = Job.changeset(%Job{}, job_attrs("DistributedTaskQueue.EmailWorker"))
      assert cs.valid?
    end

    test "accepts a module the local node has not loaded" do
      cs = Job.changeset(%Job{}, job_attrs("MyApp.SomeWorkerOnAnotherNode"))
      assert cs.valid?
    end

    test "rejects malformed module names" do
      for bad <- @garbage do
        cs = Job.changeset(%Job{}, job_attrs(bad))
        refute cs.valid?, "expected #{inspect(bad)} to be rejected"
        assert errors_on(cs).worker_module != []
      end
    end
  end

  describe "CronJob.changeset/2" do
    defp cron_attrs(worker_module) do
      %{
        name: "cron-#{System.unique_integer([:positive])}",
        queue_name: "q",
        worker_module: worker_module,
        payload: %{},
        interval_seconds: 300
      }
    end

    test "accepts a well-formed module name" do
      cs = CronJob.changeset(%CronJob{}, cron_attrs("DistributedTaskQueue.EmailWorker"))
      assert cs.valid?
    end

    test "rejects malformed module names" do
      for bad <- @garbage do
        cs = CronJob.changeset(%CronJob{}, cron_attrs(bad))
        refute cs.valid?, "expected #{inspect(bad)} to be rejected"
        assert errors_on(cs).worker_module != []
      end
    end
  end
end
