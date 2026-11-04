defmodule DistributedTaskQueueWeb.Auth do
  @moduledoc """
  Access control for the HTTP API, the console and LiveDashboard.

  Configured at runtime (see `config/runtime.exs`):

    * `:api_keys` — `nil` leaves `/api/*` open (dev, test). A list makes a
      matching `Authorization: Bearer <key>` header required. An empty list
      locks the API entirely, which is what production gets when
      `DTQ_API_KEYS` is unset.

    * `:admin_auth` — `:disabled` (dev, test) leaves the console and
      LiveDashboard open. `[username: _, password: _]` puts both behind HTTP
      basic auth. `:public_console` leaves the console open but keeps
      LiveDashboard locked, for a public demo.

  Comparisons use `Plug.Crypto.secure_compare/2` so response timing does not
  leak how much of a key was right.
  """

  @app :distributed_task_queue

  def api_keys, do: Application.get_env(@app, :api_keys)

  def admin_auth, do: Application.get_env(@app, :admin_auth, :disabled)

  @doc "Whether `key` is one of the configured API keys."
  def valid_api_key?(key) when is_binary(key) do
    Enum.any?(api_keys() || [], &Plug.Crypto.secure_compare(&1, key))
  end

  def valid_api_key?(_), do: false

  @doc """
  What `scope` (`:console` or `:dashboard`) requires: `:open`, `:locked`, or
  `{:basic, username, password}`.
  """
  def requirement(scope) do
    case {admin_auth(), scope} do
      {:disabled, _} -> :open
      {:public_console, :console} -> :open
      {:public_console, :dashboard} -> :locked
      {creds, _} when is_list(creds) -> {:basic, creds[:username], creds[:password]}
    end
  end

  def valid_credentials?(username, password) do
    case admin_auth() do
      creds when is_list(creds) ->
        # Evaluate both so a wrong username costs the same as a wrong password.
        user_ok = Plug.Crypto.secure_compare(username, creds[:username])
        pass_ok = Plug.Crypto.secure_compare(password, creds[:password])
        user_ok and pass_ok

      _ ->
        false
    end
  end
end
