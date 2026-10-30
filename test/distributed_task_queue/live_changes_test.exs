defmodule DistributedTaskQueue.LiveChangesTest.SlowWorker do
  @behaviour DistributedTaskQueue.Worker

  def perform(%{"sleep_ms" => ms}) do
    Process.sleep(ms)
    :ok
  end
end

defmodule DistributedTaskQueue.LiveChangesTest do
  @moduledoc """
  Changes made at runtime (from the console or API) take effect without
  restarting anything: new jobs are picked up immediately, and a concurrency
  change resizes the running manager.
  """
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{CronScheduler, Job, QueueCache, Repo, WorkerSupervisor}

  @slow "DistributedTaskQueue.LiveChangesTest.SlowWorker"
  @quick "DistributedTaskQueue.EmailWorker"

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))

    on_exit(fn ->
      DynamicSupervisor.which_children(WorkerSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
      end)
    end)

    :ok
  end

  defp new_queue(concurrency) do
    {:ok, queue} =
      DistributedTaskQueue.add_queue(%{
        "name" => "live-#{System.unique_integer([:positive])}",
        "max_concurrent_jobs" => concurrency
      })

    queue
  end

  defp enqueue(queue, worker, payload \\ %{}) do
    {:ok, job} =
      DistributedTaskQueue.add_job(queue.name, %{"worker_module" => worker, "payload" => payload})

    job
  end

  # Polls until `fun` returns truthy or `timeout_ms` passes.
  defp eventually(fun, timeout_ms \\ 1_000) do
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

  describe "enqueueing" do
    test "a job on an idle queue starts running immediately" do
      queue = new_queue(1)
      job = enqueue(queue, @quick)

      # The manager's regular poll is 5s; this must not wait for it.
      assert eventually(fn -> status(job) == "completed" end, 1_000)
    end

    test "a job enqueued while the manager is busy uses a free slot without waiting" do
      queue = new_queue(2)
      slow = enqueue(queue, @slow, %{"sleep_ms" => 2_000})
      assert eventually(fn -> status(slow) == "started" end)

      quick = enqueue(queue, @quick)

      # Previously the manager only re-polled when a running job finished.
      assert eventually(fn -> status(quick) == "completed" end, 1_000)
      assert status(slow) == "started"
    end
  end

  describe "resuming" do
    test "a resumed queue claims its pending jobs immediately" do
      queue = new_queue(1)
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      job = enqueue(queue, @quick)

      Process.sleep(100)
      assert status(job) == "pending"

      {:ok, _} = DistributedTaskQueue.resume_queue(queue.name)
      assert eventually(fn -> status(job) == "completed" end, 1_000)
    end
  end

  describe "changing concurrency" do
    test "raising it lets waiting jobs start without a restart" do
      queue = new_queue(1)
      a = enqueue(queue, @slow, %{"sleep_ms" => 1_500})
      b = enqueue(queue, @slow, %{"sleep_ms" => 1_500})

      assert eventually(fn -> status(a) == "started" end)
      assert status(b) == "pending"

      {:ok, _} = DistributedTaskQueue.update_queue(queue, %{"max_concurrent_jobs" => 2})

      assert eventually(fn -> status(b) == "started" end, 500)
    end

    test "lowering it lets in-flight jobs finish and then runs at the new limit" do
      queue = new_queue(2)
      a = enqueue(queue, @slow, %{"sleep_ms" => 600})
      b = enqueue(queue, @slow, %{"sleep_ms" => 600})
      assert eventually(fn -> status(a) == "started" and status(b) == "started" end)

      {:ok, _} = DistributedTaskQueue.update_queue(queue, %{"max_concurrent_jobs" => 1})
      c = enqueue(queue, @slow, %{"sleep_ms" => 600})
      d = enqueue(queue, @slow, %{"sleep_ms" => 600})

      # Neither in-flight job was killed.
      assert eventually(fn -> status(a) == "completed" and status(b) == "completed" end, 1_500)

      # From here on, never more than one job at a time.
      assert eventually(
               fn ->
                 statuses = [status(c), status(d)]
                 assert Enum.count(statuses, &(&1 == "started")) <= 1
                 Enum.all?(statuses, &(&1 == "completed"))
               end,
               3_000
             )
    end
  end

  describe "cron created at runtime" do
    test "a cron due in 2 seconds has run its job about 2 seconds later" do
      start_supervised!(CronScheduler)
      queue = new_queue(1)
      started = System.monotonic_time(:millisecond)

      {:ok, cron} =
        DistributedTaskQueue.create_cron_job(%{
          name: "live-cron-#{System.unique_integer([:positive])}",
          queue_name: queue.name,
          worker_module: @quick,
          interval_seconds: 2,
          payload: %{}
        })

      completed? = fn ->
        Repo.exists?(from(j in Job, where: j.cron_job_id == ^cron.id and j.status == "completed"))
      end

      # next_run_at is stored to the second, so "2s" lands somewhere in 1–3s.
      assert eventually(completed?, 4_000)
      assert System.monotonic_time(:millisecond) - started < 4_000
    end
  end
end
