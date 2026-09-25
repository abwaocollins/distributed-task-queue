defmodule DistributedTaskQueue.Events do
  @moduledoc """
  Bridges the `[:dtq, :job, *]` and `[:dtq, :cron, *]` telemetry events onto
  `Phoenix.PubSub`, so anything that wants to react to queue activity (the
  dashboard) subscribes to one topic instead of attaching telemetry handlers.

  PubSub broadcasts reach every connected node, so a dashboard on one node sees
  jobs run on another.

  Messages arrive as `{:dtq_event, event, metadata}` where `event` is the
  telemetry event name, e.g. `[:dtq, :job, :completed]`.
  """

  require Logger

  @topic "dtq:events"
  @handler_id "dtq-pubsub-bridge"

  @events [
    [:dtq, :job, :started],
    [:dtq, :job, :completed],
    [:dtq, :job, :failed],
    [:dtq, :cron, :fired],
    [:dtq, :cron, :skipped],
    [:dtq, :cron, :failed]
  ]

  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(DistributedTaskQueue.PubSub, @topic)

  @doc """
  Attach the telemetry handler. Idempotent: attaching twice is a no-op rather
  than an error, so it is safe to call from `Application.start/2`.
  """
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  Broadcast a change that did not come from telemetry, such as a requeue or a
  pause made from the dashboard, so every open dashboard refreshes.
  """
  def broadcast(event, metadata \\ %{}) do
    Phoenix.PubSub.broadcast(DistributedTaskQueue.PubSub, @topic, {:dtq_event, event, metadata})
  end

  # Runs inside the process that emitted the event (a worker, the scheduler).
  # Telemetry permanently detaches a handler that raises, so a broadcast failure
  # (e.g. PubSub not started yet) must never escape.
  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    broadcast(event, metadata)
  rescue
    e -> Logger.debug("DistributedTaskQueue.Events: broadcast failed: #{Exception.message(e)}")
  end
end
