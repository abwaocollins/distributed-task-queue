defmodule DistributedTaskQueue.Worker do
  @callback perform(payload :: map()) :: :ok | {:error, reason :: term()}

  def run_job(job) do
    try do
      module = job.worker_module |> String.split(".") |> Module.concat()
      apply(module, :perform, [job.payload])
      DistributedTaskQueue.update_job_status(job.id, "completed")
    rescue
      e ->
        _error = Exception.message(e)
        new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
        DistributedTaskQueue.update_job_status(job.id, new_status)
    end
  end
end
