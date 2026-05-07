defmodule DistributedTaskQueue.Worker do
  @callback perform(payload :: map()) :: :ok | {:error, reason :: term()}

  def run_job(job) do
    try do
      module = job.worker_module |> String.split(".") |> Module.concat()
      case apply(module, :perform, [job.payload]) do
        :ok -> DistributedTaskQueue.update_job_status(job.id, "completed")
        {:error, reason} -> handle_failure(job, reason)
      end
    rescue
      e -> handle_failure(job, Exception.message(e))
    end
  end

  defp handle_failure(job, reason) do
    reason_str = if is_binary(reason), do: reason, else: inspect(reason)
    new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
    DistributedTaskQueue.update_job_status(job.id, new_status, reason_str)
  end
end
