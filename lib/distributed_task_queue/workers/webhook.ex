defmodule DistributedTaskQueue.Workers.Webhook do
  @moduledoc """
  Delivers a webhook job: one HTTP request per attempt, recorded in the
  job's delivery history.

  The outcome decides what the queue does next. 2xx completes the job.
  408, 429, 5xx, a timeout or a transport error is worth retrying. Any other
  4xx, any 3xx, a refused target or an invalid payload dead-letters at once,
  because sending the same request again would get the same answer.
  """

  @behaviour DistributedTaskQueue.Worker

  require Logger

  alias DistributedTaskQueue.Webhooks
  alias DistributedTaskQueue.Webhooks.{Request, Signature, Target}

  # Lowercased names the service sets itself. A caller copy of any of these is
  # dropped, so a job can't impersonate another job or forge a signature.
  @service_headers ~w(user-agent x-dtq-job-id x-dtq-attempt x-dtq-signature)

  # Matches the cap Webhooks.record_delivery/2 applies to response_body.
  @max_body_bytes 2048

  @doc "The `worker_module` string stored on webhook jobs."
  @spec module_name() :: String.t()
  def module_name, do: inspect(__MODULE__)

  @impl true
  def perform_job(job) do
    with {:ok, request} <- normalize(job.payload),
         :ok <- check_target(request["url"]) do
      deliver(job, request)
    end
  end

  # Jobs created before validation existed may hold anything; nothing has been
  # sent yet, so there is no delivery to record.
  defp normalize(payload) do
    case Request.normalize(payload || %{}) do
      {:ok, request} ->
        {:ok, request}

      {:error, errors} ->
        details = Enum.map_join(errors, "; ", fn {field, msg} -> "#{field} #{msg}" end)
        {:discard, "The webhook request is invalid: #{details}."}
    end
  end

  # Checked here, right before sending, rather than only at enqueue: DNS can
  # change between the two, and so can the config. A small window remains
  # between this lookup and Finch's own (DNS rebinding); closing it would mean
  # connecting to the checked address directly, which is out of scope here.
  defp check_target(url) do
    case Target.check(url) do
      :ok -> :ok
      # DNS failures are often temporary (a resolver blip, a record not yet
      # propagated), so they are worth retrying. Nothing was sent either way.
      {:error, :unresolvable} -> {:error, Target.reason_text(:unresolvable)}
      {:error, reason} -> {:discard, Target.reason_text(reason)}
    end
  end

  defp deliver(job, request) do
    body = request["body"]
    headers = build_headers(job, request["headers"], body || "")
    timeout = request["timeout_ms"]

    t0 = System.monotonic_time(:millisecond)

    finch_request = Finch.build(request["method"], request["url"], headers, body)
    result = send_within(finch_request, timeout)

    duration = System.monotonic_time(:millisecond) - t0
    base = %{method: request["method"], url: request["url"], duration_ms: duration}

    case result do
      {:ok, status, resp_body} ->
        record(job, Map.merge(base, %{status_code: status, response_body: resp_body}))
        outcome(status)

      {:error, message} ->
        record(job, Map.put(base, :error, message))
        {:error, message}
    end
  end

  # Finch's own timeouts cover waiting for the response but not the TCP
  # connect, which uses the pool's default. Running the request in a task
  # bounds the whole call, so a blackholed host fails within timeout_ms too.
  defp send_within(finch_request, timeout) do
    task =
      Task.async(fn ->
        try do
          stream(finch_request, timeout)
        rescue
          e -> {:error, "Could not reach the receiver (#{Exception.message(e)})."}
        catch
          :exit, reason -> {:error, "Could not reach the receiver (#{inspect(reason)})."}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, timeout_message(timeout)}
    end
  end

  # Streams rather than buffers: only the first @max_body_bytes are kept for
  # the delivery record, so a receiver sending a huge body can't make the
  # worker hold all of it in memory. Halting closes the connection early.
  defp stream(finch_request, timeout) do
    acc = %{status: nil, body: [], size: 0}

    collect = fn
      {:status, status}, acc ->
        {:cont, %{acc | status: status}}

      {:data, data}, acc ->
        take = min(byte_size(data), @max_body_bytes - acc.size)
        acc = %{acc | body: [acc.body, binary_part(data, 0, take)], size: acc.size + take}
        if acc.size >= @max_body_bytes, do: {:halt, acc}, else: {:cont, acc}

      _headers_or_trailers, acc ->
        {:cont, acc}
    end

    opts = [receive_timeout: timeout, request_timeout: timeout]

    case Finch.stream_while(finch_request, DistributedTaskQueue.Finch, acc, collect, opts) do
      {:ok, %{status: status} = acc} when is_integer(status) ->
        {:ok, status, IO.iodata_to_binary(acc.body)}

      {:ok, _no_status} ->
        {:error, "Could not reach the receiver (no response status)."}

      {:error, exception, _acc} ->
        {:error, transport_message(exception, timeout)}
    end
  end

  defp build_headers(job, caller_headers, signed_body) do
    caller =
      Enum.reject(caller_headers, fn {name, _} -> String.downcase(name) in @service_headers end)

    service = [
      {"user-agent", user_agent()},
      {"x-dtq-job-id", to_string(job.id)},
      {"x-dtq-attempt", to_string(job.attempts + 1)}
    ]

    signature =
      case Webhooks.secret() do
        nil ->
          []

        secret ->
          [{"x-dtq-signature", Signature.header(signed_body, secret, System.os_time(:second))}]
      end

    caller ++ service ++ signature
  end

  defp user_agent do
    "dtq-webhook/" <> to_string(Application.spec(:distributed_task_queue, :vsn))
  end

  # The request was already sent, so a failed insert must not fail the job:
  # a retry would deliver the webhook a second time.
  defp record(job, attrs) do
    case Webhooks.record_delivery(job, attrs) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Could not record webhook delivery for job #{job.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp outcome(status) when status in 200..299, do: :ok

  defp outcome(status) when status in [408, 429] or status in 500..599,
    do: {:error, "The receiver answered #{describe(status)}; it will be retried."}

  defp outcome(status) when status in 300..399,
    do:
      {:discard,
       "The receiver answered with a redirect (#{describe(status)}), but redirects are not " <>
         "followed. Point the webhook at the final URL."}

  defp outcome(status) when status in 400..499,
    do: {:discard, "The receiver rejected it (#{describe(status)}) — retrying would not help."}

  defp outcome(status),
    do:
      {:discard,
       "The receiver sent an unexpected response (#{describe(status)}) — retrying would not help."}

  defp describe(status) do
    "#{status} #{Plug.Conn.Status.reason_phrase(status)}"
  rescue
    ArgumentError -> to_string(status)
  end

  defp transport_message(%Mint.TransportError{reason: :timeout}, timeout),
    do: timeout_message(timeout)

  defp transport_message(exception, _timeout),
    do: "Could not reach the receiver (#{Exception.message(exception)})."

  defp timeout_message(timeout), do: "No response within #{format_ms(timeout)}."

  defp format_ms(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp format_ms(ms), do: "#{ms}ms"
end
