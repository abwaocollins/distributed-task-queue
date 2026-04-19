defmodule DistributedTaskQueue.Worker do
  @callback perform(payload :: map()) :: :ok | {:error, reason :: term()}

  def run_job(job) do
    try do
      module = job.worker_module |> String.split(".") |> Module.concat()
      case apply(module, :perform, [job.payload]) do
        :ok ->
          DistributedTaskQueue.update_job_status(job.id, "completed")
        {:error, reason} ->
          DistributedTaskQueue.add_job_error(job.id, reason)
          new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
          DistributedTaskQueue.update_job_status(job.id, new_status)
      end
    rescue
      e ->
        error = Exception.message(e)
        DistributedTaskQueue.add_job_error(job.id, error)
        new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
        DistributedTaskQueue.update_job_status(job.id, new_status)
    end
  end
end
