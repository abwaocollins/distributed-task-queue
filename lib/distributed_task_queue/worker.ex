defmodule DistributedTaskQueue.Worker do
  @callback perform(payload :: map()) :: :ok | {:error, reason :: term()}

  def run_job(job) do
    metadata = %{
      job_id: job.id,
      queue_name: job.queue_name,
      worker_module: job.worker_module
    }

    :telemetry.execute([:dtq, :job, :started], %{system_time: System.system_time()}, metadata)
    t0 = System.monotonic_time(:millisecond)

    try do
      module = job.worker_module |> String.split(".") |> Module.concat()

      case apply(module, :perform, [job.payload]) do
        :ok ->
          duration = System.monotonic_time(:millisecond) - t0
          :telemetry.execute([:dtq, :job, :completed], %{duration: duration}, metadata)
          DistributedTaskQueue.update_job_status(job.id, "completed")

        {:error, reason} ->
          reason_str = if is_binary(reason), do: reason, else: inspect(reason)
          duration = System.monotonic_time(:millisecond) - t0
          :telemetry.execute([:dtq, :job, :failed], %{duration: duration}, Map.put(metadata, :reason, reason_str))
          handle_failure(job, reason_str)
      end
    rescue
      e ->
        reason_str = Exception.message(e)
        duration = System.monotonic_time(:millisecond) - t0
        :telemetry.execute([:dtq, :job, :failed], %{duration: duration}, Map.put(metadata, :reason, reason_str))
        handle_failure(job, reason_str)
    end
  end

  defp handle_failure(job, reason_str) do
    new_status = if job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"
    DistributedTaskQueue.update_job_status(job.id, new_status, reason_str)
  end
end
