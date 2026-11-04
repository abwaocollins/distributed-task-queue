defmodule DistributedTaskQueue.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DistributedTaskQueueWeb.Telemetry,
        DistributedTaskQueue.Repo,
        {DNSCluster,
         query: Application.get_env(:distributed_task_queue, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DistributedTaskQueue.PubSub},
        {Finch, name: DistributedTaskQueue.Finch},
        {Registry, keys: :unique, name: DistributedTaskQueue.WorkerRegistry},
        DistributedTaskQueue.WorkerSupervisor,
        DistributedTaskQueue.QueueCache
      ] ++
        # Before QueueBootstrapper, so jobs this node orphaned when it last went
        # down are back in the queue by the time its managers start claiming.
        optional_child(:start_reaper, DistributedTaskQueue.Reaper) ++
        [DistributedTaskQueue.QueueBootstrapper] ++
        # Seeds demo queues and crons before the scheduler starts reading them.
        # Both start before the Endpoint, as do the queue managers that run
        # demo and webhook jobs, so nothing on this path may call
        # Endpoint.url/0: Target.demo_receiver_url/1 reads the endpoint config
        # instead. That keeps this order (and Reaper before QueueBootstrapper)
        # without delaying job processing until the web server is up.
        optional_child(:demo_mode, DistributedTaskQueue.Demo, false) ++
        optional_child(:start_cron_scheduler, DistributedTaskQueue.CronScheduler) ++
        [DistributedTaskQueueWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DistributedTaskQueue.Supervisor]

    # Attached before the tree starts so the first jobs QueueBootstrapper runs
    # are already bridged onto PubSub for the dashboard.
    DistributedTaskQueue.Events.attach()

    Supervisor.start_link(children, opts)
  end

  # Both are safe to run on every node — CronScheduler claims each tick with a
  # conditional UPDATE, and the Reaper locks the rows it rescues. Disabled in
  # test, where their timers would poll outside the Ecto sandbox.
  defp optional_child(flag, child, default \\ true) do
    if Application.get_env(:distributed_task_queue, flag, default), do: [child], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DistributedTaskQueueWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
