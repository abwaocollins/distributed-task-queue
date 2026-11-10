defmodule DistributedTaskQueue.JobRetryStopTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{Job, QueueCache, QueueManager, Repo}

  @slow "DistributedTaskQueue.Test.SlowWorker"

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))

    {:ok, queue} =
      DistributedTaskQueue.add_queue(%{
        "name" => "retry-stop-#{System.unique_integer([:positive])}",
        "max_concurrent_jobs" => 1
      })

    %{queue: queue}
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(25) && do_eventually(fun, deadline)
    end
  end

  defp status(job), do: Repo.get!(Job, job.id).status

  describe "retry_job/1" do
    test "runs a finished job again from scratch", %{queue: queue} do
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)

      for attrs <- [
            [status: "completed", completed_at: DateTime.utc_now(), worker_id: 1],
            [status: "discarded", dead_letter: true, attempts: 3, error_message: "boom"],
            [status: "cancelled"]
          ] do
        job = insert(:job, [queue_name: queue.name, attempted_by: "n@h:q"] ++ attrs)

        assert {:ok, retried} = DistributedTaskQueue.retry_job(job.id)
        assert retried.status == "pending"
        assert retried.attempts == 0
        refute retried.dead_letter
        assert is_nil(retried.error_message)
        assert is_nil(retried.worker_id)
        assert is_nil(retried.attempted_by)
        assert is_nil(retried.completed_at)
      end
    end

    test "makes a scheduled or backing-off job due now", %{queue: queue} do
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      later = DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.truncate(:second)
      scheduled = insert(:job, queue_name: queue.name, scheduled_at: later)

      backing_off =
        insert(:job, queue_name: queue.name, status: "retryable", next_retry_at: later)

      assert {:ok, %{scheduled_at: nil}} = DistributedTaskQueue.retry_job(scheduled.id)

      assert {:ok, %{status: "pending", next_retry_at: nil}} =
               DistributedTaskQueue.retry_job(backing_off.id)
    end

    test "the retried job actually runs", %{queue: queue} do
      job = insert(:job, queue_name: queue.name, status: "cancelled")
      assert {:ok, _} = DistributedTaskQueue.retry_job(job.id)
      assert eventually(fn -> status(job) == "completed" end)
    end

    test "refuses a running, deleted or missing job", %{queue: queue} do
      running = insert(:job, queue_name: queue.name, status: "started", worker_id: 1)
      deleted = insert(:job, queue_name: queue.name, status: "deleted")

      assert {:error, :job_running} = DistributedTaskQueue.retry_job(running.id)
      assert {:error, :not_retryable} = DistributedTaskQueue.retry_job(deleted.id)
      assert {:error, :not_found} = DistributedTaskQueue.retry_job(0)
      assert status(running) == "started"
    end
  end

  describe "cancel_job/1" do
    test "a waiting job never runs", %{queue: queue} do
      later = DateTime.utc_now() |> DateTime.add(2, :second)

      {:ok, job} =
        DistributedTaskQueue.add_job(queue.name, %{
          "worker_module" => "DistributedTaskQueue.EmailWorker",
          "payload" => %{},
          "scheduled_at" => later
        })

      assert {:ok, %{status: "cancelled"}} = DistributedTaskQueue.cancel_job(job.id)

      Process.sleep(2_500)
      assert status(job) == "cancelled"
      assert is_nil(Repo.get!(Job, job.id).started_at)
    end

    test "a running job is killed and its slot freed", %{queue: queue} do
      {:ok, running} =
        DistributedTaskQueue.add_job(queue.name, %{
          "worker_module" => @slow,
          "payload" => %{"sleep_ms" => 60_000}
        })

      assert eventually(fn -> status(running) == "started" end)

      [{_pid, {task_pid, _}}] =
        :sys.get_state(manager(queue)).task_slots |> Map.to_list()

      assert {:ok, %{status: "cancelled"}} = DistributedTaskQueue.cancel_job(running.id)
      refute Process.alive?(task_pid)

      # The only slot is free again, so the next job runs straight away.
      {:ok, next} =
        DistributedTaskQueue.add_job(queue.name, %{
          "worker_module" => "DistributedTaskQueue.EmailWorker",
          "payload" => %{}
        })

      assert eventually(fn -> status(next) == "completed" end)
      assert status(running) == "cancelled"
      assert MapSet.size(QueueManager.running_job_ids(queue.name)) == 0
    end

    test "a running job whose worker is gone is still marked stopped", %{queue: queue} do
      job =
        insert(:job,
          queue_name: queue.name,
          status: "started",
          worker_id: 1,
          attempted_by: "gone@nowhere:#{queue.name}"
        )

      assert {:ok, %{status: "cancelled"}} = DistributedTaskQueue.cancel_job(job.id)

      # If that worker reports back later, it cannot undo the stop.
      assert {:ok, _} = DistributedTaskQueue.update_job_status(job.id, "completed")
      assert status(job) == "cancelled"
    end

    test "refuses a finished or missing job", %{queue: queue} do
      done = insert(:job, queue_name: queue.name, status: "completed")
      assert {:error, :already_finished} = DistributedTaskQueue.cancel_job(done.id)
      assert {:error, :not_found} = DistributedTaskQueue.cancel_job(0)
      assert status(done) == "completed"
    end
  end

  defp manager(queue) do
    [{pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)
    pid
  end
end
