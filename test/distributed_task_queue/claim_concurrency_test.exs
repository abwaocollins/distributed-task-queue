defmodule DistributedTaskQueue.ClaimConcurrencyTest do
  @moduledoc """
  Concurrency guarantees for the two claim paths, exercised against real
  separate database connections.

  The Ecto sandbox hands every process in a test the *same* connection, which
  silently serialises anything that looks concurrent — a test written against it
  proves nothing about two nodes racing. So this module opts out of the sandbox
  (`:auto` mode), talks to the test database directly, and cleans up after
  itself. `async: false`, and ExUnit runs sync modules serially after the async
  ones, so nothing else is using the sandbox while the mode is switched.

  Locks are held from a raw Postgrex connection to force the exact interleaving
  two nodes hit, rather than hoping the scheduler produces it.
  """
  use ExUnit.Case, async: false

  alias DistributedTaskQueue.{CronJob, CronScheduler, Job, Queue, Repo, WorkerSupervisor}
  import Ecto.Query

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    queue_name = "claim-race-#{System.unique_integer([:positive])}"

    Repo.insert!(%Queue{
      name: queue_name,
      description: "concurrency test",
      max_concurrent_jobs: 3,
      paused: false
    })

    on_exit(fn ->
      # Stop workers before deleting the rows they are polling for.
      WorkerSupervisor.stop_queue(queue_name)
      Repo.delete_all(from j in Job, where: j.queue_name == ^queue_name)
      Repo.delete_all(from c in CronJob, where: c.queue_name == ^queue_name)
      Repo.delete_all(from q in Queue, where: q.name == ^queue_name)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    {:ok, queue: queue_name}
  end

  describe "claim_job/2 across connections" do
    test "steps over a row another connection holds locked and takes the next one", %{queue: q} do
      older = insert_job!(q, -20)
      newer = insert_job!(q, -10)

      conn = open_raw_conn()
      lock_row!(conn, "jobs", older.id)

      task = Task.async(fn -> DistributedTaskQueue.claim_job(q, 1) end)

      # Blocking here instead of skipping is the failure this guards against:
      # it would stall every other node behind one locked row.
      assert {:ok, {:ok, claimed}} = Task.yield(task, 5_000)
      assert claimed.id == newer.id

      release!(conn)
    end

    test "reports no_jobs when the only claimable row is locked, and leaves it alone", %{queue: q} do
      job = insert_job!(q, -20)

      conn = open_raw_conn()
      lock_row!(conn, "jobs", job.id)

      task = Task.async(fn -> DistributedTaskQueue.claim_job(q, 1) end)
      assert {:ok, {:error, :no_jobs}} = Task.yield(task, 5_000)

      release!(conn)

      reloaded = Repo.get!(Job, job.id)
      assert is_nil(reloaded.worker_id)
      assert reloaded.status == "pending"
    end

    test "a row mid-claim on another connection is never stolen", %{queue: q} do
      job = insert_job!(q, -20)

      conn = open_raw_conn()

      # Another node claiming it for real, transaction still open.
      Postgrex.query!(conn, "BEGIN", [])

      Postgrex.query!(
        conn,
        "UPDATE jobs SET worker_id = 99, status = 'started', attempted_by = 'other-node' WHERE id = $1",
        [job.id]
      )

      # SKIP LOCKED means this does not even wait — the row is locked, so it is
      # passed over, and nothing else is claimable.
      task = Task.async(fn -> DistributedTaskQueue.claim_job(q, 1) end)
      assert {:ok, {:error, :no_jobs}} = Task.yield(task, 5_000)

      Postgrex.query!(conn, "COMMIT", [])

      # The regression this pins: previously the claimer blocked here, re-checked
      # its `id IN (subquery)` against a stale snapshot, matched anyway, and
      # overwrote worker_id 99. The job ran on both nodes and attempted_by kept
      # only the second writer, so the duplicate left no trace.
      reloaded = Repo.get!(Job, job.id)
      assert reloaded.worker_id == 99
      assert reloaded.attempted_by == "other-node"
    end

    test "concurrent claimers hand a single job to exactly one worker", %{queue: q} do
      job = insert_job!(q, -20)

      results =
        1..8
        |> Task.async_stream(&DistributedTaskQueue.claim_job(q, &1),
          max_concurrency: 8,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [{:ok, claimed}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert claimed.id == job.id
      assert Repo.get!(Job, job.id).worker_id == claimed.worker_id
    end

    test "concurrent claimers spread across rows and never double-claim", %{queue: q} do
      for i <- 1..5, do: insert_job!(q, -i * 10)

      claimed =
        1..5
        |> Task.async_stream(&DistributedTaskQueue.claim_job(q, &1),
          max_concurrency: 5,
          timeout: 15_000
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, job}} -> [job.id]
          {:ok, {:error, :no_jobs}} -> []
        end)

      # The guarantee: no row goes to two workers.
      assert claimed == Enum.uniq(claimed)

      # SKIP LOCKED spreads them instead of serialising everyone behind the
      # oldest row. Not asserting all 5 — under a simultaneous burst a worker
      # can still come back empty (measured 3–5 of 5). That costs one poll
      # cycle, never a job.
      assert length(claimed) >= 2

      rows =
        Repo.all(
          from j in Job,
            where: j.queue_name == ^q,
            select: {j.id, j.status, j.worker_id},
            order_by: j.id
        )

      started = for {id, "started", _} <- rows, do: id
      unclaimed = for {id, "pending", nil} <- rows, do: id

      # Every row taken must be a row some caller was told it got. A claimer that
      # marks rows `started` and then reports :no_jobs strands them there with
      # nobody running them — that is what the old single-statement form did.
      assert MapSet.new(started) == MapSet.new(claimed),
             "claimed=#{inspect(claimed)} rows=#{inspect(rows)}"

      # Nothing stranded: every row is either taken or still claimable.
      assert length(claimed) + length(unclaimed) == 5,
             "claimed=#{inspect(claimed)} unclaimed=#{inspect(unclaimed)} rows=#{inspect(rows)}"
    end
  end

  describe "cron claim_tick across connections" do
    test "a tick already advanced by another connection is not fired again", %{queue: q} do
      cron = insert_cron!(q)

      conn = open_raw_conn()
      Postgrex.query!(conn, "BEGIN", [])

      # Another node winning the tick: advance the schedule, hold the row lock.
      Postgrex.query!(
        conn,
        "UPDATE cron_jobs SET next_run_at = now() + interval '5 minutes', last_run_at = now() WHERE id = $1",
        [cron.id]
      )

      # This scheduler's SELECT predates the commit, so it still sees the cron as
      # due and blocks inside claim_tick's conditional UPDATE.
      task = Task.async(fn -> CronScheduler.fire_due_crons() end)
      refute Task.yield(task, 500), "expected the scheduler to block on the cron row lock"

      Postgrex.query!(conn, "COMMIT", [])
      assert {:ok, _} = Task.yield(task, 10_000)

      # EvalPlanQual re-check against the committed row: next_run_at is now in
      # the future, the conditional UPDATE matches nothing, no job is enqueued.
      assert Repo.aggregate(from(j in Job, where: j.cron_job_id == ^cron.id), :count) == 0
    end

    test "concurrent scheduler passes enqueue the job exactly once", %{queue: q} do
      cron = insert_cron!(q)

      1..5
      |> Task.async_stream(fn _ -> CronScheduler.fire_due_crons() end,
        max_concurrency: 5,
        timeout: 15_000
      )
      |> Stream.run()

      assert Repo.aggregate(from(j in Job, where: j.cron_job_id == ^cron.id), :count) == 1
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp insert_job!(queue_name, age_seconds) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(%Job{
      queue_name: queue_name,
      worker_module: "DistributedTaskQueue.EmailWorker",
      payload: %{"to" => "test@example.com"},
      status: "pending",
      inserted_at: NaiveDateTime.add(now, age_seconds, :second),
      updated_at: now
    })
  end

  defp insert_cron!(queue_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%CronJob{
      name: "claim-race-cron-#{System.unique_integer([:positive])}",
      worker_module: "DistributedTaskQueue.EmailWorker",
      queue_name: queue_name,
      payload: %{"to" => "test@example.com"},
      interval_seconds: 300,
      # Overlap is checked before the claim; leave it open so these tests
      # exercise the claim itself.
      overlap: true,
      enabled: true,
      next_run_at: DateTime.add(now, -1, :second)
    })
  end

  # A connection outside the Repo pool, so it can hold a transaction open while
  # the code under test runs on a different one.
  defp open_raw_conn do
    cfg = Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: cfg[:hostname],
        port: cfg[:port] || 5432,
        username: cfg[:username],
        password: cfg[:password],
        database: cfg[:database]
      )

    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    conn
  end

  defp lock_row!(conn, table, id) do
    Postgrex.query!(conn, "BEGIN", [])
    Postgrex.query!(conn, "SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [id])
  end

  defp release!(conn), do: Postgrex.query!(conn, "ROLLBACK", [])
end
