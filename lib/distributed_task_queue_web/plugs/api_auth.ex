defmodule DistributedTaskQueueWeb.Plugs.ApiAuth do
  @moduledoc "Requires `Authorization: Bearer <key>` on `/api/*` when API keys are configured."
  import Plug.Conn

  alias DistributedTaskQueueWeb.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      is_nil(Auth.api_keys()) -> conn
      Auth.valid_api_key?(bearer_token(conn)) -> conn
      true -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="dtq"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "missing or invalid API key"}))
    |> halt()
  end
end
