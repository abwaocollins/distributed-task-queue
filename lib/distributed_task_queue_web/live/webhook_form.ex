defmodule DistributedTaskQueueWeb.WebhookForm do
  @moduledoc """
  Turns the params of a webhook form (see `WebhookFields`) into what
  `Webhooks` takes, and its error messages back into form errors. Shared by
  every console form that creates a webhook, so they all follow one rule set.

  The forms are built from raw params rather than a changeset: a webhook's
  fields live inside a job's or cron's payload, so there is no schema to cast
  into.
  """

  alias DistributedTaskQueue.Webhooks.Request

  @request_fields %{
    "url" => :url,
    "method" => :method,
    "headers" => :headers,
    "body" => :body,
    "timeout_ms" => :timeout_ms
  }

  @doc """
  The header rows to show. Rows posted by the form win; with none posted the
  `current` rows stay (adding a row sends no params).
  """
  @spec header_rows(map, [map]) :: [map]
  def header_rows(%{"headers" => headers}, _current) when is_map(headers) do
    headers
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
    |> Enum.map(fn {_, row} -> %{key: row["key"] || "", value: row["value"] || ""} end)
  end

  def header_rows(_params, current), do: current

  @doc "Rows for a stored headers map, sorted by name, credentials masked."
  @spec rows_for(map) :: [map]
  def rows_for(headers) when is_map(headers) do
    headers
    |> Request.redact_headers()
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> %{key: key, value: value} end)
  end

  @doc """
  The request fields (`url`, `method`, `headers`, `body`) from form params and
  header rows, ready for `Webhooks.enqueue/1` or `Webhooks.cron_attrs/1`.
  """
  @spec request_attrs(map, [map]) :: map
  def request_attrs(params, rows) do
    headers =
      for %{key: key, value: value} <- rows, String.trim(key) != "", into: %{} do
        {String.trim(key), value}
      end

    %{
      "url" => params["url"],
      "method" => params["method"],
      "headers" => headers,
      "body" => decode_body(params["body"])
    }
  end

  # JSON objects and arrays are sent as JSON; anything else goes as typed.
  defp decode_body(nil), do: nil

  defp decode_body(text) do
    trimmed = String.trim(text)

    case Jason.decode(trimmed) do
      _ when trimmed == "" -> nil
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
      _ -> text
    end
  end

  @doc """
  One request problem reported under the payload, either as "field: message"
  or as a plain sentence about the target (shown by the URL), as a form error.
  """
  @spec payload_error(String.t()) :: {atom, {String.t(), list}}
  def payload_error(message) do
    case Regex.run(~r/\A(\w+): (.*)\z/s, message) do
      [_, name, rest] when is_map_key(@request_fields, name) ->
        {Map.fetch!(@request_fields, name), {rest, []}}

      _ ->
        {:url, {message, []}}
    end
  end
end
