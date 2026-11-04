defmodule DistributedTaskQueueWeb.Plugs.AdminAuth do
  @moduledoc """
  HTTP basic auth for the console (`scope: :console`) and LiveDashboard
  (`scope: :dashboard`).

  On success it marks the session, which `DistributedTaskQueueWeb.ConsoleAuth`
  checks when the LiveView socket mounts. The plug only sees the first HTTP
  request; the socket that follows is a separate connection.
  """
  import Plug.Conn

  alias DistributedTaskQueueWeb.Auth

  @session_key "dtq_admin"

  def session_key, do: @session_key

  def init(opts), do: Keyword.fetch!(opts, :scope)

  def call(conn, scope) do
    case Auth.requirement(scope) do
      :open ->
        conn

      :locked ->
        conn |> send_resp(404, "Not Found") |> halt()

      {:basic, _user, _pass} ->
        with {user, pass} <- Plug.BasicAuth.parse_basic_auth(conn),
             true <- Auth.valid_credentials?(user, pass) do
          put_session(conn, @session_key, true)
        else
          _ -> conn |> Plug.BasicAuth.request_basic_auth(realm: "DTQ console") |> halt()
        end
    end
  end
end
