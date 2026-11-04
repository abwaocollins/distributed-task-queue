defmodule DistributedTaskQueue.Webhooks.Signature do
  @moduledoc """
  Signs outgoing webhook bodies so receivers can verify who sent them.

  The header looks like `t=<unix>,v1=<lowercase hex>`. The HMAC-SHA256 covers
  `"<unix>.<body>"`, so the timestamp is bound to the body and a captured
  request cannot be replayed with a fresh timestamp.
  """

  @doc "Builds the signature header for `body` at time `unix`."
  @spec header(binary, binary, integer) :: String.t()
  def header(body, secret, unix) do
    "t=#{unix},v1=#{sign(body, secret, unix)}"
  end

  @doc """
  Checks a signature header against `body`.

  Rejects timestamps more than `max_age_s` seconds old, or that far in the
  future. The comparison is constant time.
  """
  @spec valid?(String.t(), binary, binary, non_neg_integer) :: boolean
  def valid?(header, body, secret, max_age_s \\ 300)

  def valid?(header, body, secret, max_age_s) when is_binary(header) do
    with {:ok, unix, given} <- parse(header),
         true <- abs(System.os_time(:second) - unix) <= max_age_s do
      Plug.Crypto.secure_compare(given, sign(body, secret, unix))
    else
      _ -> false
    end
  end

  def valid?(_header, _body, _secret, _max_age_s), do: false

  defp sign(body, secret, unix) do
    :crypto.mac(:hmac, :sha256, secret, "#{unix}.#{body}") |> Base.encode16(case: :lower)
  end

  defp parse(header) do
    parts =
      header
      |> String.split(",")
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> {String.trim(k), String.trim(v)}
          _ -> {part, nil}
        end
      end)

    with %{"t" => t, "v1" => v1} when is_binary(v1) <- parts,
         {unix, ""} <- Integer.parse(t) do
      {:ok, unix, v1}
    else
      _ -> :error
    end
  end
end
