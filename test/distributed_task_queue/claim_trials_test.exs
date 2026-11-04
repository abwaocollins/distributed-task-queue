defmodule DistributedTaskQueue.ClaimTrialsTest do
  @moduledoc """
  Repeated-trial harness behind the published claim-safety numbers.

  Excluded from the normal run. Run it with:

      mix test --only trials
      DTQ_TRIALS=200 DTQ_JOBS=10 DTQ_CLAIMERS=10 mix test --only trials

  Each trial inserts `jobs` pending rows and fires `claimers` concurrent
  `claim_job/2` calls on separate connections (sandbox off, same setup as
  `ClaimConcurrencyTest`). Every trial must show zero duplicate claims, zero
  stranded rows and zero lost rows. How many of the rows got claimed is
  reported, not asserted: under a simultaneous burst a claimer can come back
  empty, which costs a poll cycle, never a job.
  """
  use ExUnit.Case, async: false

  alias DistributedTaskQueue.{Job, Queue, Repo}
  import Ecto.Query

  @moduletag :trials
  @moduletag timeout: :infinity

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    queue = "claim-trials-#{System.unique_integer([:positive])}"
    Repo.insert!(%Queue{name: queue, max_concurrent_jobs: 1, paused: false})

    on_exit(fn ->
      Repo.delete_all(from(j in Job, where: j.queue_name == ^queue))
      Repo.delete_all(from(q in Queue, where: q.name == ^queue))
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    {:ok, queue: queue}
  end

  test "claim_job never double-claims, strands or loses a row", %{queue: queue} do
    trials = env_int("DTQ_TRIALS", 40)
    jobs = env_int("DTQ_JOBS", 5)
    claimers = env_int("DTQ_CLAIMERS", 5)

    started = System.monotonic_time(:millisecond)
    results = Enum.map(1..trials, fn _ -> run_trial(queue, jobs, claimers) end)
    elapsed_ms = System.monotonic_time(:millisecond) - started

    claimed_counts = Enum.map(results, & &1.claimed)
    total_claims = Enum.sum(claimed_counts)

    IO.puts("""

    claim_job trials: #{trials} × #{jobs} jobs × #{claimers} concurrent claimers
      duplicate claims: #{Enum.sum(Enum.map(results, & &1.duplicates))}
      stranded rows:    #{Enum.sum(Enum.map(results, & &1.stranded))}
      lost rows:        #{Enum.sum(Enum.map(results, & &1.lost))}
      claimed per trial: min #{Enum.min(claimed_counts)}, max #{Enum.max(claimed_counts)}, \
    mean #{Float.round(total_claims / trials, 2)} of #{min(jobs, claimers)}
      claims/sec:       #{Float.round(total_claims / max(elapsed_ms, 1) * 1000, 1)} \
    (#{total_claims} claims in #{elapsed_ms} ms, single node, includes setup)
    """)

    for {r, i} <- Enum.with_index(results, 1) do
      assert r.duplicates == 0, "trial #{i}: #{inspect(r)}"
      assert r.stranded == 0, "trial #{i}: #{inspect(r)}"
      assert r.lost == 0, "trial #{i}: #{inspect(r)}"
    end
  end

  defp run_trial(queue, jobs, claimers) do
    Repo.delete_all(from(j in Job, where: j.queue_name == ^queue))
    ids = for i <- 1..jobs, do: insert_job!(queue, -i).id

    claimed =
      1..claimers
      |> Task.async_stream(&DistributedTaskQueue.claim_job(queue, &1),
        max_concurrency: claimers,
        timeout: 15_000
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, job}} -> [job.id]
        {:ok, {:error, :no_jobs}} -> []
      end)

    rows =
      Repo.all(
        from(j in Job, where: j.queue_name == ^queue, select: {j.id, j.status, j.worker_id})
      )

    started = for {id, "started", _} <- rows, do: id
    pending = for {id, "pending", nil} <- rows, do: id

    %{
      claimed: length(claimed),
      duplicates: length(claimed) - length(Enum.uniq(claimed)),
      # Marked started, but no caller was told it got the row.
      stranded: length(started -- claimed),
      # Neither claimed nor still claimable.
      lost: length(ids) - length(started) - length(pending)
    }
  end

  defp insert_job!(queue, age_seconds) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(%Job{
      queue_name: queue,
      worker_module: "DistributedTaskQueue.EmailWorker",
      payload: %{},
      status: "pending",
      inserted_at: NaiveDateTime.add(now, age_seconds, :second),
      updated_at: now
    })
  end

  defp env_int(name, default),
    do: name |> System.get_env(to_string(default)) |> String.to_integer()
end
