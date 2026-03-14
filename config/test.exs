import Config

# db configs
# Configure your database
config :distributed_task_queue, DistributedTaskQueue.Repo,
  username: "postgres",
  password: "password",
  hostname: "localhost",
  database: "distributed_task_queue_test",
  stacktrace: true,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :distributed_task_queue, DistributedTaskQueueWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lV5gPQXHJr89A8LW35ZmxFMrDDrm+grTsUNdXLz394/oUqalW8ocEo1SVM6axLQU",
  server: false

# In test we don't send emails
config :distributed_task_queue, DistributedTaskQueue.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
