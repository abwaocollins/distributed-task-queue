defmodule DistributedTaskQueue.QueueManagerScheduledTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.QueueCache

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "a job scheduled for later runs on time even though the queue was empty" do
    {:ok, queue} =
      DistributedTaskQueue.add_queue(%{
        "name" => "scheduled-mgr-#{System.unique_integer([:positive])}",
        "max_concurrent_jobs" => 2
      })

    run_at = DateTime.utc_now() |> DateTime.add(2, :second)

    {:ok, job} =
      DistributedTaskQueue.add_job(queue.name, %{
        "worker_module" => "DistributedTaskQueue.EmailWorker",
        "payload" => %{},
        "scheduled_at" => run_at
      })

    # Nothing is due yet, so the manager's first poll finds no jobs. It must
    # stay up and come back when the job is due rather than stopping.
    Process.sleep(500)
    assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)
    assert DistributedTaskQueue.get_job(job.id).status == "pending"

    assert wait_until(fn -> DistributedTaskQueue.get_job(job.id).status == "completed" end, 4_000)

    completed = DistributedTaskQueue.get_job(job.id)
    assert DateTime.compare(completed.started_at, DateTime.truncate(run_at, :second)) != :lt
  end

  defp wait_until(fun, timeout) when timeout <= 0, do: fun.()

  defp wait_until(fun, timeout) do
    if fun.() do
      true
    else
      Process.sleep(100)
      wait_until(fun, timeout - 100)
    end
  end
end
