defmodule DistributedTaskQueue.WorkerDispatchSecurityTest do
  @moduledoc """
  `worker_module` is attacker-controllable on any deployment that exposes the
  HTTP API, so dispatch must refuse anything that is not a registered worker.

  These tests pin the two failure modes that a naive `Module.concat/1` +
  `apply/3` dispatch allows:

    * minting a brand new atom per request (atoms are never garbage collected,
      so an unbounded stream of them exhausts the VM's atom table), and
    * invoking `perform/1` on any loaded module that happens to export it.
  """
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.Worker

  # Exports perform/1 but never declared the behaviour. Dispatch must still
  # refuse it — exporting a function is not the same as opting in.
  defmodule LookalikeWorker do
    def perform(_payload), do: :ok
  end

  defmodule RegisteredWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: :ok
  end

  describe "resolve/1" do
    test "accepts a module that declares the Worker behaviour" do
      assert {:ok, RegisteredWorker} =
               Worker.resolve("DistributedTaskQueue.WorkerDispatchSecurityTest.RegisteredWorker")
    end

    test "refuses a loaded module that exports perform/1 without the behaviour" do
      assert {:error, :not_a_worker} =
               Worker.resolve("DistributedTaskQueue.WorkerDispatchSecurityTest.LookalikeWorker")
    end

    test "refuses a module that does not exist" do
      assert {:error, :unknown_worker_module} = Worker.resolve("Totally.Bogus.Module")
    end

    test "refuses a string that is not a module name at all" do
      assert {:error, :unknown_worker_module} = Worker.resolve("../../etc/passwd")
    end

    test "does not create an atom for an unknown module name" do
      name = "Nonexistent.Worker.From.Atom.Test.#{System.unique_integer([:positive])}"

      assert {:error, :unknown_worker_module} = Worker.resolve(name)

      # If resolve/1 had interned the atom, to_existing_atom/1 would succeed.
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end
  end

  describe "run_job/1 dispatch" do
    setup do
      {:ok, queue: insert(:queue)}
    end

    test "does not invoke perform/1 on a module lacking the behaviour", %{queue: queue} do
      job =
        insert(:job,
          queue_name: queue.name,
          worker_module: "DistributedTaskQueue.WorkerDispatchSecurityTest.LookalikeWorker",
          max_attempts: 1
        )

      Worker.run_job(job)

      reloaded = DistributedTaskQueue.get_job(job.id)
      assert reloaded.status == "discarded"
      assert reloaded.error_message =~ "not a registered worker"
    end

    test "fails the job instead of crashing on an unknown module", %{queue: queue} do
      job =
        insert(:job,
          queue_name: queue.name,
          worker_module: "Totally.Bogus.Module",
          max_attempts: 1
        )

      Worker.run_job(job)

      reloaded = DistributedTaskQueue.get_job(job.id)
      assert reloaded.status == "discarded"
      assert reloaded.error_message =~ "not a registered worker"
    end

    test "emits :failed telemetry rather than :completed for a rejected module", %{queue: queue} do
      job =
        insert(:job,
          queue_name: queue.name,
          worker_module: "Totally.Bogus.Module",
          max_attempts: 1
        )

      test_pid = self()
      handler = "reject-#{job.id}"

      :telemetry.attach_many(
        handler,
        [[:dtq, :job, :completed], [:dtq, :job, :failed]],
        fn event, _measurements, metadata, _ -> send(test_pid, {:telemetry, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Worker.run_job(job)

      job_id = job.id
      assert_receive {:telemetry, [:dtq, :job, :failed], %{job_id: ^job_id}}
      refute_received {:telemetry, [:dtq, :job, :completed], _}
    end

    test "still runs a properly registered worker", %{queue: queue} do
      job =
        insert(:job,
          queue_name: queue.name,
          worker_module: "DistributedTaskQueue.WorkerDispatchSecurityTest.RegisteredWorker"
        )

      Worker.run_job(job)

      assert DistributedTaskQueue.get_job(job.id).status == "completed"
    end
  end
end
