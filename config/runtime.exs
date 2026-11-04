import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/distributed_task_queue start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :distributed_task_queue, DistributedTaskQueueWeb.Endpoint, server: true
end

# Public-demo data generator (DistributedTaskQueue.Demo). Never in test.
if config_env() != :test and System.get_env("DTQ_DEMO_MODE") == "true" do
  config :distributed_task_queue, demo_mode: true
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :distributed_task_queue, DistributedTaskQueue.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :distributed_task_queue, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # API keys for /api/*, comma-separated. Unset means the API is locked: an open
  # job-creation endpoint on the internet will be abused.
  #
  # DTQ_DEMO_API_KEY is a showcase key that the public intro page may display.
  # It is a real API key, so only set it on a deployment where that is intended.
  demo_api_key =
    case System.get_env("DTQ_DEMO_API_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end

  if demo_api_key do
    config :distributed_task_queue, :demo_api_key, demo_api_key
  end

  config :distributed_task_queue,
         :api_keys,
         (System.get_env("DTQ_API_KEYS") || "")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Kernel.++(List.wrap(demo_api_key))

  # Webhook deliveries are signed with this secret, so receivers can verify
  # them. Refuse to start without it rather than send unsigned requests.
  webhook_secret =
    case System.get_env("DTQ_WEBHOOK_SECRET") do
      secret when is_binary(secret) and secret != "" ->
        secret

      _ ->
        raise """
        environment variable DTQ_WEBHOOK_SECRET is missing.
        It signs outgoing webhook requests. You can generate one with: mix phx.gen.secret
        """
    end

  config :distributed_task_queue, :webhooks,
    secret: webhook_secret,
    targets: if(System.get_env("DTQ_WEBHOOK_TARGETS") == "demo", do: :demo_receivers, else: :any),
    allow_private_targets: false

  # Basic auth for the console and LiveDashboard. A public demo can opt out for
  # the console only with DTQ_PUBLIC_CONSOLE=true; LiveDashboard stays locked.
  admin_auth =
    case {System.get_env("DTQ_ADMIN_USERNAME"), System.get_env("DTQ_ADMIN_PASSWORD")} do
      {user, pass} when is_binary(user) and is_binary(pass) and pass != "" ->
        [username: user, password: pass]

      _ ->
        if System.get_env("DTQ_PUBLIC_CONSOLE") == "true" do
          :public_console
        else
          raise """
          DTQ_ADMIN_USERNAME and DTQ_ADMIN_PASSWORD are not set.
          The console can pause, delete and requeue; it will not start unprotected.
          Set both, or set DTQ_PUBLIC_CONSOLE=true to deliberately run a public console.
          """
        end
    end

  config :distributed_task_queue, :admin_auth, admin_auth

  config :distributed_task_queue, DistributedTaskQueueWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :distributed_task_queue, DistributedTaskQueueWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :distributed_task_queue, DistributedTaskQueueWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :distributed_task_queue, DistributedTaskQueue.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
