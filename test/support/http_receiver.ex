defmodule DistributedTaskQueue.HttpReceiver do
  @moduledoc """
  A throwaway HTTP server for tests that need a real receiver.

  Every request is forwarded to the test process as
  `{:received, method, path, headers, body}`, then answered by `responder`.
  """

  import ExUnit.Callbacks, only: [start_supervised: 1]

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test_pid: test_pid, responder: responder}) do
      {:ok, body, conn} = read_all(conn, "")
      send(test_pid, {:received, conn.method, conn.request_path, conn.req_headers, body})
      responder.(conn)
    end

    defp read_all(conn, acc) do
      case Elixir.Plug.Conn.read_body(conn) do
        {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
        {:more, chunk, conn} -> read_all(conn, acc <> chunk)
      end
    end
  end

  @doc "Starts a receiver on an ephemeral loopback port and returns its base URL."
  @spec start((Elixir.Plug.Conn.t() -> Elixir.Plug.Conn.t())) :: String.t()
  def start(responder) when is_function(responder, 1) do
    opts = [
      plug: {__MODULE__.Plug, %{test_pid: self(), responder: responder}},
      ip: :loopback,
      port: 0,
      startup_log: false,
      # A responder that sleeps must not hold up the end of the test.
      thousand_island_options: [shutdown_timeout: 100]
    ]

    # A unique id so one test can run several receivers.
    {:ok, pid} = start_supervised(Supervisor.child_spec({Bandit, opts}, id: make_ref()))

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end
end
