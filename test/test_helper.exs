# `trials` is the repeated-trial claim harness: slow, run on demand.
ExUnit.start(exclude: [:trials])

# QueueBootstrapper boots queues (and creates the webhooks queue) in the
# background as the app starts. Let it finish while the repo is still in
# auto mode, or its queries race the switch to :manual and crash it. Then
# undo what it did, so every test starts from an empty database.
wait_for_bootstrapper = fn wait_for_bootstrapper, tries ->
  if Process.whereis(DistributedTaskQueue.QueueBootstrapper) && tries > 0 do
    Process.sleep(50)
    wait_for_bootstrapper.(wait_for_bootstrapper, tries - 1)
  end
end

wait_for_bootstrapper.(wait_for_bootstrapper, 100)

for queue <- DistributedTaskQueue.Repo.all(DistributedTaskQueue.Queue) do
  DistributedTaskQueue.WorkerSupervisor.stop_queue(queue.name)
  DistributedTaskQueue.QueueCache.delete(queue.name)
end

DistributedTaskQueue.Repo.delete_all(DistributedTaskQueue.Queue)

Ecto.Adapters.SQL.Sandbox.mode(DistributedTaskQueue.Repo, :manual)
