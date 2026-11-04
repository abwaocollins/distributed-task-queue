defmodule DistributedTaskQueueWeb.ConsoleAuth do
  @moduledoc """
  `on_mount` guard for the console's LiveViews.

  Basic auth runs in `Plugs.AdminAuth` on the initial HTTP request, which marks
  the session. The LiveView socket is a separate connection the plug never
  sees, so without this check its events — pause, delete, requeue — would be
  reachable by anyone holding a session that never authenticated.
  """
  import Phoenix.LiveView, only: [redirect: 2]

  alias DistributedTaskQueueWeb.{Auth, Plugs.AdminAuth}

  def on_mount(:default, params, session, socket),
    do: on_mount(:console, params, session, socket)

  def on_mount(scope, _params, session, socket) when scope in [:console, :dashboard] do
    case Auth.requirement(scope) do
      :open ->
        {:cont, socket}

      _ ->
        if session[AdminAuth.session_key()] == true,
          do: {:cont, socket},
          else: {:halt, redirect(socket, to: "/")}
    end
  end
end
