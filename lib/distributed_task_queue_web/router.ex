defmodule DistributedTaskQueueWeb.Router do
  use DistributedTaskQueueWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DistributedTaskQueueWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug DistributedTaskQueueWeb.Plugs.ApiAuth
  end

  # No auth: the service calls these like an external system would.
  pipeline :demo_receiver do
    plug :accepts, ["json"]
  end

  pipeline :console_auth do
    plug DistributedTaskQueueWeb.Plugs.AdminAuth, scope: :console
  end

  pipeline :dashboard_auth do
    plug DistributedTaskQueueWeb.Plugs.AdminAuth, scope: :dashboard
  end

  scope "/", DistributedTaskQueueWeb do
    pipe_through [:browser, :console_auth]

    live_session :console,
      on_mount: [DistributedTaskQueueWeb.ConsoleAuth, DistributedTaskQueueWeb.LiveRefresh] do
      live "/", OverviewLive, :index

      live "/queues", QueuesLive, :index
      live "/queues/new", QueuesLive, :new
      live "/queues/:name/edit", QueuesLive, :edit

      live "/jobs", JobsLive, :index
      live "/jobs/new", JobsLive, :new
      live "/jobs/:id", JobLive, :show

      live "/dead-letter", DeadLetterLive, :index

      live "/cron", CronLive, :index
      live "/cron/new", CronLive, :new
      live "/cron/:id/edit", CronLive, :edit
    end
  end

  scope "/api", DistributedTaskQueueWeb do
    pipe_through :api

    resources "/queues", QueueController, only: [:index, :create]
    post "/queues/:name/start", QueueController, :start
    post "/queues/:name/stop", QueueController, :stop
    delete "/queues/:name", QueueController, :delete

    post "/webhooks", WebhookController, :create

    post "/jobs/:id/requeue", JobController, :requeue
    post "/jobs/requeue_dead_letter", JobController, :requeue_all
    resources "/jobs", JobController, only: [:index, :show, :create, :delete]

    post "/cron_jobs/:id/enable", CronJobController, :enable
    post "/cron_jobs/:id/disable", CronJobController, :disable
    resources "/cron_jobs", CronJobController, except: [:new, :edit]
  end

  scope "/demo", DistributedTaskQueueWeb do
    pipe_through :demo_receiver

    match :*, "/receivers/:name", DemoReceiverController, :receive
  end

  import Phoenix.LiveDashboard.Router

  # In every environment, behind admin basic auth wherever credentials are set.
  # The `dtq.*` metrics and BEAM process/memory views are worth showing in
  # production; open to the internet they would leak far too much.
  scope "/admin" do
    pipe_through [:browser, :dashboard_auth]

    live_dashboard "/dashboard",
      metrics: DistributedTaskQueueWeb.Telemetry,
      on_mount: [{DistributedTaskQueueWeb.ConsoleAuth, :dashboard}]
  end

  # Swoosh mailbox preview in development only.
  if Application.compile_env(:distributed_task_queue, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
