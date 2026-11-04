defmodule DistributedTaskQueue.ReaperTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{Job, QueueCache, Reaper, Repo}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp started_job(queue, attrs) do
    insert(
      :job,
      Keyword.merge(
        [
          queue_name: queue.name,
          status: "started",
          worker_id: 1,
          started_at: ago(2 * 3_600),
          attempted_by: "other@node:#{queue.name}"
        ],
        attrs
      )
    )
  end

  describe "rescue_stale/1" do
    test "a job started longer ago than the limit goes back to retry" do
      queue = insert(:queue)
      job = started_job(queue, attempts: 0, max_attempts: 3)

      assert {:ok, 1} = Reaper.rescue_stale(3_600)

      rescued = Repo.get!(Job, job.id)
      assert rescued.status == "retryable"
      assert rescued.attempts == 1
      assert is_nil(rescued.worker_id)
      assert rescued.error_message =~ "orphaned"
      assert DateTime.compare(rescued.next_retry_at, DateTime.utc_now()) == :gt
    end

    test "a job on its last attempt is dead-lettered instead" do
      queue = insert(:queue)
      job = started_job(queue, attempts: 2, max_attempts: 3)

      assert {:ok, 1} = Reaper.rescue_stale(3_600)

      rescued = Repo.get!(Job, job.id)
      assert rescued.status == "discarded"
      assert rescued.dead_letter
    end

    test "a job started within the limit is left alone" do
      queue = insert(:queue)
      job = started_job(queue, started_at: ago(60))

      assert {:ok, 0} = Reaper.rescue_stale(3_600)
      assert Repo.get!(Job, job.id).status == "started"
    end

    test "a slow job this node is still running is never rescued" do
      queue = insert(:queue, max_concurrent_jobs: 1)

      {:ok, job} =
        DistributedTaskQueue.add_job(queue.name, %{
          "worker_module" => "DistributedTaskQueue.Test.SlowWorker",
          "payload" => %{"sleep_ms" => 1_000}
        })

      assert wait_for(fn -> Repo.get!(Job, job.id).status == "started" end)

      # Make it look ancient: the limit alone would call it orphaned.
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [started_at: ago(2 * 3_600)])

      assert {:ok, 0} = Reaper.rescue_stale(3_600)
      assert Repo.get!(Job, job.id).status == "started"
    end

    test "starts the queue's manager so the rescued job runs again" do
      queue = insert(:queue)
      started_job(queue, [])

      assert {:ok, 1} = Reaper.rescue_stale(3_600)
      assert [{_pid, _}] = Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue.name)
    end

    test "emits a rescued telemetry event" do
      queue = insert(:queue)
      job = started_job(queue, [])
      handler = "reaper-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:dtq, :job, :rescued],
        fn _, measurements, meta, _ -> send(test_pid, {:rescued, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Reaper.rescue_stale(3_600)

      assert_receive {:rescued, %{count: 1}, %{job_id: id, reason: :stale}}
      assert id == job.id
    end
  end

  describe "rescue_own_node/0" do
    test "rescues jobs this node had started, however recent" do
      queue = insert(:queue)
      job = started_job(queue, started_at: ago(5), attempted_by: "#{Node.self()}:#{queue.name}")
      other = started_job(queue, started_at: ago(5))

      assert {:ok, 1} = Reaper.rescue_own_node()

      assert Repo.get!(Job, job.id).status == "retryable"
      assert Repo.get!(Job, other.id).status == "started"
    end
  end

  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      fun.() || (Process.sleep(25) && false)
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > deadline end)
  end
end
