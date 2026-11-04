defmodule DistributedTaskQueue.Webhooks do
  @moduledoc """
  The webhook context: signing configuration and the delivery history of
  webhook jobs.
  """
  import Ecto.Query

  alias DistributedTaskQueue.{Job, Repo}
  alias DistributedTaskQueue.Webhooks.Delivery

  # Callers only need a hint of what came back; the full body could be huge
  # or sensitive.
  @max_body_bytes 2048

  @doc "The signing secret from config, or nil when none is set."
  @spec secret() :: String.t() | nil
  def secret do
    :distributed_task_queue |> Application.get_env(:webhooks, []) |> Keyword.get(:secret)
  end

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
    |> String.replace_invalid()
    |> String.replace(<<0>>, "")
    |> cut(limit)
  end

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
