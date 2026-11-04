defmodule DistributedTaskQueue.Worker do
  @callback perform(payload :: map()) ::
              :ok | {:error, reason :: term()} | {:discard, reason :: term()}

  # Workers that need more than the payload (job id, attempt count) implement
  # this instead of perform/1. Exactly one of the two is expected; both are
  # optional so a worker is not forced to stub the one it does not use.
  @callback perform_job(job :: DistributedTaskQueue.Job.t()) ::
              :ok | {:error, reason :: term()} | {:discard, reason :: term()}

  @optional_callbacks perform: 1, perform_job: 1

  @doc ~S"""
  Resolves a stored `worker_module` string to a dispatchable module.

  `worker_module` originates from client input on any deployment exposing the
  HTTP API, so this is the trust boundary for job execution. Two properties
  matter:

    * **No atom creation.** `Module.safe_concat/1` raises rather than interning
      an atom for a name the VM has never seen. `Module.concat/1` would mint
      one per call, and atoms are never garbage collected — an unbounded stream
      of unknown names would exhaust the atom table and take the node down.

    * **Opt-in only.** Exporting `perform/1` is not consent to be run as a
      worker; the module must declare `@behaviour DistributedTaskQueue.Worker`.
      Without this, any loaded module exporting `perform/1` is reachable with a
      caller-controlled payload.

  Returns `{:ok, module}` or `{:error, :unknown_worker_module | :not_a_worker}`.
  """
  def resolve(worker_module) when is_binary(worker_module) do
    module = worker_module |> String.split(".") |> Module.safe_concat()

    if registered_worker?(module), do: {:ok, module}, else: {:error, :not_a_worker}
  rescue
    ArgumentError -> {:error, :unknown_worker_module}
  end

  def resolve(_), do: {:error, :unknown_worker_module}

  defp registered_worker?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__info__, 1) and
      __MODULE__ in declared_behaviours(module)
  end

  defp declared_behaviours(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  def run_job(job) do
    metadata = %{
      job_id: job.id,
      queue_name: job.queue_name,
      worker_module: job.worker_module
    }

    :telemetry.execute([:dtq, :job, :started], %{system_time: System.system_time()}, metadata)
    t0 = System.monotonic_time(:millisecond)

    case resolve(job.worker_module) do
      {:ok, module} -> dispatch(job, module, metadata, t0)
      {:error, reason} -> fail(job, rejection_message(job.worker_module, reason), metadata, t0)
    end
  end

  defp dispatch(job, module, metadata, t0) do
    result =
      if function_exported?(module, :perform_job, 1),
        do: module.perform_job(job),
        else: module.perform(job.payload)

    case result do
      :ok ->
        duration = System.monotonic_time(:millisecond) - t0
        :telemetry.execute([:dtq, :job, :completed], %{duration: duration}, metadata)
        DistributedTaskQueue.update_job_status(job.id, "completed")

      {:error, reason} ->
        fail(job, reason_to_string(reason), metadata, t0)

      # A permanent failure: retrying cannot help, so skip the attempts check.
      {:discard, reason} ->
        fail(job, reason_to_string(reason), metadata, t0, true)
    end
  rescue
    e -> fail(job, Exception.message(e), metadata, t0)
  end

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp fail(job, reason_str, metadata, t0, force_discard? \\ false) do
    duration = System.monotonic_time(:millisecond) - t0
    :telemetry.execute([:dtq, :job, :failed], %{duration: duration}, Map.put(metadata, :reason, reason_str))
    handle_failure(job, reason_str, force_discard?)
  end

  defp rejection_message(worker_module, :unknown_worker_module),
    do: "#{inspect(worker_module)} is not a registered worker: no such module"

  defp rejection_message(worker_module, :not_a_worker),
    do:
      "#{inspect(worker_module)} is not a registered worker: " <>
        "it does not declare @behaviour DistributedTaskQueue.Worker"

  defp handle_failure(job, reason_str, force_discard?) do
    new_status =
      if force_discard? or job.attempts + 1 >= job.max_attempts, do: "discarded", else: "retryable"

    DistributedTaskQueue.update_job_status(job.id, new_status, reason_str)
  end
end
