defmodule DistributedTaskQueue.Webhooks.Target do
  @moduledoc """
  Decides whether a webhook URL may be called from this server.

  Two guards, both needed on a public demo:

    * Private addresses. Without this, anyone could use the service to reach
      loopback, the LAN or a cloud metadata endpoint (SSRF).
    * Target mode. In `:demo_receivers` mode only this app's own demo
      receiver URLs are allowed, so the live demo can't be used as a proxy.

  Defaults come from `config :distributed_task_queue, :webhooks`.
  """

  import Bitwise

  alias DistributedTaskQueueWeb.Endpoint

  @demo_receiver_names ["payments", "email", "warehouse"]

  # Bounds each DNS lookup so a slow resolver can't stall enqueue or a worker.
  @dns_timeout_ms 5_000

  @type reason :: :private_address | :unresolvable | :not_a_demo_receiver

  @doc """
  Returns `:ok` when `url` may be called.

  Options (each defaults to the `:webhooks` config):

    * `:targets` - `:any` or `:demo_receivers`.
    * `:allow_private` - when true, private addresses are allowed.
  """
  @spec check(String.t(), keyword) :: :ok | {:error, reason}
  def check(url, opts \\ []) when is_binary(url) do
    config = Application.get_env(:distributed_task_queue, :webhooks, [])
    targets = Keyword.get(opts, :targets, Keyword.get(config, :targets, :any))

    allow_private =
      Keyword.get(opts, :allow_private, Keyword.get(config, :allow_private_targets, false))

    case targets do
      # The receivers live on this app's own endpoint, which may well be
      # localhost, so an exact match is the whole check; the private-address
      # rule would otherwise refuse the demo's own URLs in dev.
      :demo_receivers -> check_demo_receiver(url)
      :any -> check_address(url, allow_private)
    end
  end

  @doc "The URL of the named demo receiver on this app's endpoint."
  @spec demo_receiver_url(String.t()) :: String.t()
  def demo_receiver_url(name), do: Endpoint.url() <> "/demo/receivers/" <> name

  @doc "The names of the built-in demo receivers."
  @spec demo_receiver_names() :: [String.t()]
  def demo_receiver_names, do: @demo_receiver_names

  @doc "A plain-English explanation of a refusal, safe to show to anyone."
  @spec reason_text(reason) :: String.t()
  def reason_text(:private_address),
    do: "That address is on a private network, so it can't be called from here."

  def reason_text(:unresolvable),
    do: "We couldn't find that address. Check the URL is spelled correctly."

  def reason_text(:not_a_demo_receiver),
    do:
      "This demo only sends to its own demo receivers: " <>
        Enum.join(@demo_receiver_names, ", ") <> "."

  defp check_demo_receiver(url) do
    allowed = Enum.map(@demo_receiver_names, &normalise(demo_receiver_url(&1)))

    # Whole-string equality, so a trailing slash, query, "/../" segment or
    # extra path never slips through the way it could with a prefix match.
    if normalise(url) in allowed, do: :ok, else: {:error, :not_a_demo_receiver}
  end

  # Scheme and host are case-insensitive and a default port may be written or
  # left out; everything else must match byte for byte.
  defp normalise(url) do
    uri = URI.parse(url)

    URI.to_string(%URI{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host)
    })
  end

  defp check_address(url, allow_private) do
    with {:ok, host} <- host(url),
         {:ok, addresses} <- resolve(host) do
      # Any blocked address is enough to refuse: a host that resolves to both
      # a public and a private address could be connected to either.
      if not allow_private and Enum.any?(addresses, &blocked?/1),
        do: {:error, :private_address},
        else: :ok
    end
  end

  # URI.parse already drops the brackets around an IPv6 literal.
  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, :unresolvable}
    end
  end

  defp resolve(host) do
    host = String.to_charlist(host)

    # parse_address handles IP literals without DNS, including the short and
    # decimal IPv4 forms ("127.1", "2130706433") that getaddrs does not.
    case :inet.parse_address(host) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        addresses =
          for family <- [:inet, :inet6],
              {:ok, ips} <- [:inet.getaddrs(host, family, @dns_timeout_ms)],
              ip <- ips,
              do: ip

        if addresses == [], do: {:error, :unresolvable}, else: {:ok, addresses}
    end
  end

  defp blocked?({0, _, _, _}), do: true
  defp blocked?({10, _, _, _}), do: true
  defp blocked?({100, b, _, _}) when b in 64..127, do: true
  defp blocked?({127, _, _, _}), do: true
  defp blocked?({169, 254, _, _}), do: true
  defp blocked?({172, b, _, _}) when b in 16..31, do: true
  defp blocked?({192, 168, _, _}), do: true
  defp blocked?({_, _, _, _}), do: false

  defp blocked?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp blocked?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true

  # IPv4-mapped (::ffff:a.b.c.d) reaches the IPv4 address it embeds.
  defp blocked?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: blocked?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  defp blocked?({_, _, _, _, _, _, _, _}), do: false
end
