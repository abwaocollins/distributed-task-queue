defmodule DistributedTaskQueue.QueueManagerPauseTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{QueueCache, WorkerSupervisor}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "a paused queue does not claim pending jobs" do
    {:ok, queue} = DistributedTaskQueue.add_queue(%{
      "name" => "pause-mgr-#{System.unique_integer([:positive])}",
      "max_concurrent_jobs" => 2
    })
    # Pause BEFORE enqueueing: add_job starts the manager and it polls at once.
    {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)

    {:ok, job} = DistributedTaskQueue.add_job(queue.name, %{
      "worker_module" => "DistributedTaskQueue.EmailWorker",
      "payload" => %{}
    })

    [{manager_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)

    # Manually trigger a poll — no waiting for the 5s timer
    send(manager_pid, :poll)
    Process.sleep(100)

    updated_job = DistributedTaskQueue.get_job(job.id)
    assert updated_job.status == "pending"
    assert is_nil(updated_job.worker_id)

    DynamicSupervisor.terminate_child(WorkerSupervisor, manager_pid)
  end
end
