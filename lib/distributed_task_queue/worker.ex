defmodule DistributedTaskQueue.Worker do
  use GenServer

  @poll_interval 5_000

  @callback perform(payload :: map()) :: :ok | {:error, reason :: term()}

  def start_link({id, queue_name}) do
    GenServer.start_link(__MODULE__, %{id: id, queue: queue_name}, name: via(queue_name, id))
  end

  def init(%{id: _id, queue: _queue} = state) do
    Process.send_after(self(), :poll, @poll_interval)
    {:ok, state}
  end

  def handle_info(:poll, state) do
    case DistributedTaskQueue.claim_job(state.queue, state.id) do
      {:ok, job} -> GenServer.cast(self(), {:execute_job, job})
      {:error, :no_jobs} -> :ok
    end

    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, state}
  end

  def handle_cast({:execute_job, job}, state) do
    run_job(job)
    {:noreply, state}
  end

  defp run_job(job) do
    module = String.to_existing_atom("#{job.worker_module}")

    try do
      apply(module, :perform, [job.payload])
      DistributedTaskQueue.update_job_status(job.id, "completed")
    rescue
      e ->
        _error = Exception.message(e)
        new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
        DistributedTaskQueue.update_job_status(job.id, new_status)
    end
  end

  defp via(queue_name, id) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, {queue_name, id}}}
  end
end
