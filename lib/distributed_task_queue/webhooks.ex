defmodule DistributedTaskQueue.Webhooks do
  @moduledoc """
  The webhook context: signing configuration and the delivery history of
  webhook jobs.
  """
  import Ecto.Query

  require Logger

  alias DistributedTaskQueue.{Job, Repo}
  alias DistributedTaskQueue.Webhooks.{Delivery, Request, Target}
  alias DistributedTaskQueue.Workers.Webhook, as: Worker

  @queue "webhooks"
  @queue_concurrency 10
  @default_max_attempts 5
  @max_delay_seconds 31_536_000

  # Callers only need a hint of what came back; the full body could be huge
  # or sensitive.
  @max_body_bytes 2048

  @doc "The signing secret from config, or nil when none is set."
  @spec secret() :: String.t() | nil
  def secret do
    :distributed_task_queue |> Application.get_env(:webhooks, []) |> Keyword.get(:secret)
  end

  @doc "Which URLs may be called: `:any` or `:demo_receivers`."
  @spec targets() :: :any | :demo_receivers
  def targets do
    :distributed_task_queue |> Application.get_env(:webhooks, []) |> Keyword.get(:targets, :any)
  end

  @doc """
  Validates a webhook request and queues it as a job on the webhooks queue.

  Takes the request fields (`url`, `method`, `headers`, `body`, `timeout_ms`)
  plus optional `queue`, `max_attempts`, and one of `delay_seconds` or
  `run_at` (ISO 8601 with offset). Errors come back as a changeset so the API
  and the console render them the same way as any other job error.
  """
  @spec enqueue(map) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, payload} <- validate_request(attrs),
         {:ok, scheduled_at} <- schedule(attrs) do
      job_attrs =
        %{
          "worker_module" => Worker.module_name(),
          "payload" => payload,
          "max_attempts" => Map.get(attrs, "max_attempts") || @default_max_attempts
        }
        |> put_scheduled_at(scheduled_at)

      DistributedTaskQueue.add_job(Map.get(attrs, "queue") || @queue, job_attrs)
    else
      {:error, field, messages} -> {:error, error_changeset(%Job{}, field, messages)}
    end
  end

  @doc """
  Creates the webhooks queue if it does not exist. An existing queue is left
  alone so an operator's concurrency change survives a restart. Never raises:
  a failure here must not stop the other queues from booting.
  """
  @spec ensure_queue() :: :ok
  def ensure_queue do
    if is_nil(DistributedTaskQueue.get_queue(@queue)) do
      DistributedTaskQueue.add_queue(%{
        "name" => @queue,
        "description" => "Outgoing webhook deliveries",
        "max_concurrent_jobs" => @queue_concurrency
      })
    end

    :ok
  rescue
    e ->
      Logger.error("[Webhooks] could not ensure the webhooks queue: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Turns a cron API payload with a `webhook` object into a webhook cron: sets
  the worker and the normalised request as payload. When the request is
  invalid the messages are left under `"webhook_errors"` for the caller to
  report.

  Params that name the webhook worker directly, with a raw `payload`, get the
  same checks (see `validate_worker_attrs/2`). `existing` is the cron being
  updated, or nil when creating; a new webhook cron defaults to
  #{@default_max_attempts} attempts. Any other params pass through unchanged.
  """
  @spec cron_attrs(map, struct | nil) :: map
  def cron_attrs(params, existing \\ nil)

  def cron_attrs(%{"webhook" => webhook} = params, existing) when is_map(webhook) do
    params = Map.delete(params, "webhook")

    case validate_request(webhook) do
      {:ok, payload} ->
        params
        |> Map.merge(%{"worker_module" => Worker.module_name(), "payload" => payload})
        |> default_max_attempts(existing)

      {:error, :payload, messages} ->
        Map.put(params, "webhook_errors", messages)
    end
  end

  def cron_attrs(%{"webhook" => _} = params, _existing) do
    params |> Map.delete("webhook") |> Map.put("webhook_errors", ["webhook: must be an object"])
  end

  def cron_attrs(params, existing) do
    case validate_worker_attrs(params, existing) do
      {:ok, attrs} ->
        if webhook_worker?(attrs["worker_module"]),
          do: default_max_attempts(attrs, existing),
          else: attrs

      {:error, messages} ->
        Map.put(params, "webhook_errors", messages)
    end
  end

  defp default_max_attempts(params, nil),
    do: Map.put_new(params, "max_attempts", @default_max_attempts)

  defp default_max_attempts(params, _existing), do: params

  @doc """
  Validates job or cron attrs that name the webhook worker directly, so a raw
  `worker_module` + `payload` can't skip the checks `enqueue/1` runs. On
  success the payload is replaced by the normalised request. Attrs for any
  other worker come back unchanged.

  `existing` is the record being updated, if any: its worker and payload
  count when `attrs` leave them out. When `attrs` change neither, nothing is
  checked, so renaming a cron does not cost a DNS lookup.
  """
  @spec validate_worker_attrs(map, struct | nil) :: {:ok, map} | {:error, [String.t()]}
  def validate_worker_attrs(attrs, existing \\ nil) do
    worker = Map.get(attrs, "worker_module", existing && existing.worker_module)
    touched? = Map.has_key?(attrs, "worker_module") or Map.has_key?(attrs, "payload")

    if touched? and webhook_worker?(worker) do
      case validate_request(Map.get(attrs, "payload", existing && existing.payload)) do
        {:ok, payload} ->
          {:ok,
           Map.merge(attrs, %{"worker_module" => Worker.module_name(), "payload" => payload})}

        {:error, :payload, messages} ->
          {:error, messages}
      end
    else
      {:ok, attrs}
    end
  end

  @doc """
  True when `worker_module` resolves to the webhook worker. Resolving rather
  than comparing strings also catches other spellings, such as an `Elixir.`
  prefix, that would run the same worker.
  """
  @spec webhook_worker?(term) :: boolean
  def webhook_worker?(worker_module),
    do: DistributedTaskQueue.Worker.resolve(worker_module) == {:ok, Worker}

  @doc """
  The payload of a job or cron, safe to show: for the webhook worker, the
  value of every credential-like header is masked.
  """
  @spec redact_payload(%{worker_module: term, payload: term}) :: term
  def redact_payload(%{worker_module: module, payload: %{"headers" => headers} = payload})
      when is_map(headers) do
    if webhook_worker?(module),
      do: Map.put(payload, "headers", Request.redact_headers(headers)),
      else: payload
  end

  def redact_payload(%{payload: payload}), do: payload

  @doc "Adds each message as an error on `field` of an empty changeset for `struct`."
  @spec error_changeset(struct, atom, [String.t()]) :: Ecto.Changeset.t()
  def error_changeset(struct, field, messages) do
    Enum.reduce(messages, Ecto.Changeset.change(struct), &Ecto.Changeset.add_error(&2, field, &1))
  end

  # Normalise first; only a well-formed request is worth a DNS lookup. An
  # unresolvable host is refused here too, since the caller can simply retry.
  # Anything that is not a map gets normalize/1's "url is required".
  defp validate_request(params) do
    case Request.normalize(params) do
      {:ok, payload} ->
        case Target.check(payload["url"]) do
          :ok -> {:ok, payload}
          {:error, reason} -> {:error, :payload, [Target.reason_text(reason)]}
        end

      {:error, errors} ->
        {:error, :payload, Enum.map(errors, fn {field, msg} -> "#{field}: #{msg}" end)}
    end
  end

  defp schedule(attrs), do: schedule(Map.get(attrs, "delay_seconds"), Map.get(attrs, "run_at"))

  defp schedule(nil, nil), do: {:ok, nil}
  defp schedule(nil, run_at), do: parse_run_at(run_at)

  defp schedule(delay, nil)
       when is_integer(delay) and delay >= 0 and delay <= @max_delay_seconds do
    {:ok, DateTime.utc_now() |> DateTime.add(delay, :second) |> DateTime.truncate(:second)}
  end

  defp schedule(_delay, nil) do
    {:error, :scheduled_at, ["delay_seconds must be an integer from 0 to #{@max_delay_seconds}"]}
  end

  defp schedule(_delay, _run_at) do
    {:error, :scheduled_at, ["give either delay_seconds or run_at, not both"]}
  end

  defp parse_run_at(run_at) when is_binary(run_at) do
    case DateTime.from_iso8601(run_at) do
      {:ok, dt, _offset} -> {:ok, dt |> DateTime.truncate(:second)}
      {:error, _} -> {:error, :scheduled_at, ["run_at must be ISO 8601 with a UTC offset"]}
    end
  end

  defp parse_run_at(_), do: {:error, :scheduled_at, ["run_at must be ISO 8601 with a UTC offset"]}

  defp put_scheduled_at(attrs, nil), do: attrs
  defp put_scheduled_at(attrs, at), do: Map.put(attrs, "scheduled_at", at)

  @doc """
  Records one delivery attempt for `job`. The number is one more than the
  highest existing one, so numbering continues across requeues. A job only
  runs on one worker at a time; the unique index is the backstop.
  """
  @spec record_delivery(Job.t(), map) :: {:ok, Delivery.t()} | {:error, Ecto.Changeset.t()}
  def record_delivery(%Job{id: job_id}, attrs) do
    max = Repo.one(from(d in Delivery, where: d.job_id == ^job_id, select: max(d.number)))

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("number", (max || 0) + 1)
      |> sanitize()

    %Delivery{job_id: job_id}
    |> Delivery.changeset(attrs)
    |> Repo.insert()
  end

  @doc "All deliveries for a job, oldest first."
  @spec list_deliveries(integer) :: [Delivery.t()]
  def list_deliveries(job_id) do
    Repo.all(from(d in Delivery, where: d.job_id == ^job_id, order_by: d.number))
  end

  # Must run after the keys are stringified in record_delivery/2, because it
  # matches on string keys.
  defp sanitize(attrs) do
    attrs
    |> clean("response_body", @max_body_bytes)
    |> clean("error", @max_body_bytes)
    |> clean("url", :infinity)
  end

  defp clean(attrs, key, limit) do
    case attrs do
      %{^key => value} when is_binary(value) -> Map.put(attrs, key, scrub(value, limit))
      _ -> attrs
    end
  end

  # Replace invalid bytes so the result is valid UTF-8, and drop NUL bytes:
  # they are valid UTF-8 but Postgres text columns reject them, which would
  # make the insert raise and lose the record. Then cut to the byte limit,
  # backing off so a multi-byte codepoint is never split.
  defp scrub(value, limit) do
    value
    |> replace_invalid()
    |> String.replace(<<0>>, "")
    |> cut(limit)
  end

  # String.replace_invalid/1 does this, but it needs Elixir 1.16 and the
  # project still supports 1.15. Each byte that does not start a valid
  # codepoint becomes U+FFFD.
  defp replace_invalid(s), do: replace_invalid(s, [])

  defp replace_invalid(<<c::utf8, rest::binary>>, acc),
    do: replace_invalid(rest, [acc, <<c::utf8>>])

  defp replace_invalid(<<_byte, rest::binary>>, acc), do: replace_invalid(rest, [acc, "�"])
  defp replace_invalid(<<>>, acc), do: IO.iodata_to_binary(acc)

  defp cut(s, :infinity), do: s

  defp cut(s, max) when byte_size(s) <= max, do: s

  defp cut(s, max) do
    # A UTF-8 codepoint is at most 4 bytes, so backing off 3 bytes suffices.
    Enum.find_value(0..3, fn back ->
      piece = binary_part(s, 0, max - back)
      if String.valid?(piece), do: piece
    end)
  end
end
