defmodule DistributedTaskQueue.WorkerTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.Worker

  defmodule SuccessWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: :ok
  end

  defmodule FailingWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: {:error, "intentional failure"}
  end

  defmodule RaisingWorker do
    @behaviour DistributedTaskQueue.Worker
    def perform(_payload), do: raise("boom")
  end

  defp attach_handler(id, events) do
    test_pid = self()

    :telemetry.attach_many(id, events, fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "emits :started and :completed for a successful job" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, worker_module: "DistributedTaskQueue.WorkerTest.SuccessWorker")
    job_id = job.id

    attach_handler("test-success-#{job_id}", [[:dtq, :job, :started], [:dtq, :job, :completed]])

    Worker.run_job(job)

    assert_receive {:telemetry, [:dtq, :job, :started], %{system_time: st}, %{job_id: ^job_id, queue_name: _, worker_module: _}}
    assert is_integer(st)

    assert_receive {:telemetry, [:dtq, :job, :completed], %{duration: d}, %{job_id: ^job_id}}
    assert is_integer(d) and d >= 0
  end

  test "emits :started and :failed for a job returning {:error, reason}" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, worker_module: "DistributedTaskQueue.WorkerTest.FailingWorker", max_attempts: 3)
    job_id = job.id

    attach_handler("test-fail-#{job_id}", [[:dtq, :job, :started], [:dtq, :job, :failed]])

    Worker.run_job(job)

    assert_receive {:telemetry, [:dtq, :job, :started], _, _}
    assert_receive {:telemetry, [:dtq, :job, :failed], %{duration: d}, %{job_id: ^job_id, reason: "intentional failure"}}
    assert is_integer(d) and d >= 0
  end

  test "emits :failed with exception message when worker raises" do
    queue = insert(:queue)
    job = insert(:job, queue_name: queue.name, worker_module: "DistributedTaskQueue.WorkerTest.RaisingWorker", max_attempts: 3)
    job_id = job.id

    attach_handler("test-raise-#{job_id}", [[:dtq, :job, :failed]])

    Worker.run_job(job)

    assert_receive {:telemetry, [:dtq, :job, :failed], %{duration: _}, %{job_id: ^job_id, reason: "boom"}}
  end
end
