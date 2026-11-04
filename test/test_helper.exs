# `trials` is the repeated-trial claim harness: slow, run on demand.
ExUnit.start(exclude: [:trials])
Ecto.Adapters.SQL.Sandbox.mode(DistributedTaskQueue.Repo, :manual)
