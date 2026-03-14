ExUnit.start()

# Start Ecto sandbox for async tests
Ecto.Adapters.SQL.Sandbox.mode(DistributedTaskQueue.Repo, :auto)
