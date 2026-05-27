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
    {:ok, job} = DistributedTaskQueue.add_job(queue.name, %{
      "worker_module" => "DistributedTaskQueue.EmailWorker",
      "payload" => %{}
    })

    # Pause the queue in the cache BEFORE starting the manager
    QueueCache.put(%{queue | paused: true})

    {:ok, manager_pid} = WorkerSupervisor.start_queue(queue.name, queue.max_concurrent_jobs)

    # Manually trigger a poll — no waiting for the 5s timer
    send(manager_pid, :poll)
    Process.sleep(100)

    updated_job = DistributedTaskQueue.get_job(job.id)
    assert updated_job.status == "pending"
    assert is_nil(updated_job.worker_id)

    DynamicSupervisor.terminate_child(WorkerSupervisor, manager_pid)
  end
end
