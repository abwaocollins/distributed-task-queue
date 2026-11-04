defmodule DistributedTaskQueue.Webhooks.Request do
  @moduledoc """
  Validation, normalisation and display redaction for webhook requests.

  Pure on purpose: no DB and no network. Whether the target host is safe to
  call is a separate check that runs where the request is actually sent.
  """

  @methods ~w(GET POST PUT PATCH DELETE)
  @schemes ~w(http https)
  @default_method "POST"
  @default_timeout_ms 15_000
  @max_timeout_ms 60_000

  @masked "••••"

  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  # Control characters except tab, plus DEL.
  @bad_value_chars ~r/[\x00-\x08\x0A-\x1F\x7F]/

  # Headers that decide how the request is framed on the wire. The HTTP client
  # sends a caller's copy instead of computing its own, so a wrong Host or
  # Content-Length would let a caller smuggle a second request to the
  # receiver. Lowercased name => how it is written in messages.
  @framing_headers %{
    "host" => "Host",
    "content-length" => "Content-Length",
    "transfer-encoding" => "Transfer-Encoding",
    "connection" => "Connection",
    "keep-alive" => "Keep-Alive",
    "te" => "TE",
    "trailer" => "Trailer",
    "upgrade" => "Upgrade",
    "expect" => "Expect",
    "proxy-connection" => "Proxy-Connection"
  }

  # A header is treated as a credential when its name contains one of these.
  # Substring matching is deliberately broad: hiding a harmless header costs
  # nothing, leaking a token does.
  @secret_fragments ~w(authorization cookie token secret key signature password credential)

  @doc "The placeholder shown in place of a redacted header value."
  @spec masked() :: String.t()
  def masked, do: @masked

  @doc """
  Validates a caller-supplied webhook description and returns the map the
  webhook worker sends. Accepts string or atom keys.
  """
  @spec normalize(map) :: {:ok, map} | {:error, [{atom, String.t()}]}
  def normalize(params) when is_map(params) do
    url = fetch(params, "url")
    method = fetch(params, "method")
    headers = fetch(params, "headers")
    body = fetch(params, "body")
    timeout = fetch(params, "timeout_ms")

    results = [
      validate_url(url),
      validate_method(method),
      validate_headers(headers),
      validate_body(body),
      validate_timeout(timeout)
    ]

    case for({:error, _} = e <- results, do: e) do
      [] ->
        [{:ok, url}, {:ok, method}, {:ok, headers}, {:ok, body}, {:ok, timeout}] = results
        {:ok, build(url, method, headers, body, timeout)}

      errors ->
        {:error, for({:error, error} <- errors, do: error)}
    end
  end

  def normalize(_), do: {:error, [{:url, "is required"}]}

  @doc "Replaces the value of every credential-like header with the mask."
  @spec redact_headers(map) :: map
  def redact_headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, value} ->
      if secret_name?(name), do: {name, @masked}, else: {name, value}
    end)
  end

  @doc """
  Resolves masked values in an edited header map back to the stored ones, so
  saving a form that only ever showed `"••••"` does not overwrite the secret.
  """
  @spec merge_masked(map, map) :: map
  def merge_masked(new_headers, stored_headers) do
    stored = Map.new(stored_headers, fn {name, value} -> {String.downcase(name), value} end)

    Map.new(new_headers, fn
      {name, @masked} -> {name, Map.get(stored, String.downcase(name), @masked)}
      pair -> pair
    end)
  end

  defp build(url, method, headers, body, timeout) do
    {encoded, json?} = body

    headers =
      if json?, do: Map.put_new(headers, "content-type", "application/json"), else: headers

    %{
      "url" => url,
      "method" => method,
      "headers" => headers,
      "body" => encoded,
      "timeout_ms" => timeout
    }
  end

  # Accept atom keys from Elixir callers and string keys from the API.
  defp fetch(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, String.to_existing_atom(key))
    end
  end

  defp validate_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in @schemes and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, {:url, "must be an http or https URL with a host"}}
    end
  end

  defp validate_url(_), do: {:error, {:url, "is required"}}

  defp validate_method(nil), do: {:ok, @default_method}

  defp validate_method(method) when is_binary(method) do
    upcased = String.upcase(method)

    if upcased in @methods,
      do: {:ok, upcased},
      else: {:error, {:method, "must be one of #{Enum.join(@methods, ", ")}"}}
  end

  defp validate_method(_), do: {:error, {:method, "must be a string"}}

  defp validate_headers(nil), do: {:ok, %{}}

  defp validate_headers(headers) when is_map(headers) do
    with :ok <- check_header_pairs(headers),
         lowered = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end),
         :ok <- check_no_case_duplicates(lowered) do
      {:ok, Map.new(lowered)}
    end
  end

  defp validate_headers(_), do: {:error, {:headers, "must be a map"}}

  defp check_header_pairs(headers) do
    cond do
      not Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end) ->
        {:error, {:headers, "names and values must be strings"}}

      not Enum.all?(headers, fn {k, _} -> Regex.match?(@header_name, k) end) ->
        {:error,
         {:headers, "names must be non-empty tokens without whitespace or control characters"}}

      framing = Enum.find_value(headers, fn {k, _} -> @framing_headers[String.downcase(k)] end) ->
        {:error, {:headers, "#{framing} is set by the service and can't be supplied"}}

      # CR/LF in a value would let a caller inject extra headers.
      not Enum.all?(headers, fn {_, v} -> not Regex.match?(@bad_value_chars, v) end) ->
        {:error, {:headers, "values must not contain control characters"}}

      true ->
        :ok
    end
  end

  # Names are case-insensitive, so two spellings of one name are ambiguous.
  defp check_no_case_duplicates(lowered) do
    if length(lowered) == lowered |> Enum.uniq_by(&elem(&1, 0)) |> length(),
      do: :ok,
      else: {:error, {:headers, "contains the same header name more than once"}}
  end

  defp validate_body(nil), do: {:ok, {nil, false}}
  defp validate_body(body) when is_binary(body), do: {:ok, {body, false}}

  defp validate_body(body) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, json} -> {:ok, {json, true}}
      {:error, _} -> {:error, {:body, "could not be encoded as JSON"}}
    end
  end

  defp validate_body(_), do: {:error, {:body, "must be a string, map or list"}}

  defp validate_timeout(nil), do: {:ok, @default_timeout_ms}

  defp validate_timeout(ms) when is_integer(ms) and ms > 0, do: {:ok, min(ms, @max_timeout_ms)}

  defp validate_timeout(_), do: {:error, {:timeout_ms, "must be a positive integer"}}

  defp secret_name?(name) do
    lowered = String.downcase(to_string(name))
    Enum.any?(@secret_fragments, &String.contains?(lowered, &1))
  end
end
