defmodule DistributedTaskQueue.QueueBootstrapperTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{QueueBootstrapper, WorkerSupervisor}

  setup do
    on_exit(fn ->
      DistributedTaskQueue.list_queues()
      |> Enum.each(fn q -> WorkerSupervisor.stop_queue(q.name) end)
    end)
    :ok
  end

  test "boots all queues from the database" do
    insert(:queue, name: "boot-test-1", max_concurrent_jobs: 2)
    insert(:queue, name: "boot-test-2", max_concurrent_jobs: 1)

    assert {:ok, :booted} = QueueBootstrapper.boot()

    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, "boot-test-1")
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, "boot-test-2")
  end

  test "does not crash when a queue is already running" do
    queue = insert(:queue, name: "already-running", max_concurrent_jobs: 1)
    WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)

    assert {:ok, :booted} = QueueBootstrapper.boot()
  end

  test "does not crash when DB has no queues" do
    assert {:ok, :booted} = QueueBootstrapper.boot()
  end
end
