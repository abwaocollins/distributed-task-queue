defmodule DistributedTaskQueueWeb.LiveRefresh do
  @moduledoc """
  `on_mount` hook that keeps every console page current.

  Subscribes to `DistributedTaskQueue.Events` (queue telemetry bridged onto
  PubSub) and calls the page's `refresh/1` when something happens. Events are
  coalesced: the first one schedules a refresh a short moment later and any
  that arrive before it fires ride along, so a burst of 500 completions costs
  one reload rather than 500.

  The delay also matters for correctness: the worker emits `:completed` /
  `:failed` just *before* it writes the new status, so reloading immediately
  would read the old row.

  A slow tick covers what telemetry does not report, such as a job enqueued
  through the API, and keeps relative timestamps current.

  Pages using this hook must export `refresh(socket) :: socket`.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias DistributedTaskQueue.{Dashboard, Events}

  @coalesce_ms 300
  @tick_ms 5_000

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      :timer.send_interval(@tick_ms, :dtq_tick)
    end

    socket =
      socket
      |> assign(refresh_pending: false)
      |> assign_shared()
      |> attach_hook(:live_refresh, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  @doc "Re-run the page's queries now. Call after a change made from the page."
  def refresh(socket) do
    socket
    |> assign(refresh_pending: false)
    |> assign_shared()
    |> socket.view.refresh()
  end

  # Assigns every page (and the layout's nav badge) reads.
  defp assign_shared(socket) do
    assign(socket, now: DateTime.utc_now(), dead_count: Dashboard.dead_count())
  end

  defp handle_info({:dtq_event, _event, _meta}, %{assigns: %{refresh_pending: true}} = socket),
    do: {:halt, socket}

  defp handle_info({:dtq_event, _event, _meta}, socket) do
    Process.send_after(self(), :dtq_refresh, @coalesce_ms)
    {:halt, assign(socket, refresh_pending: true)}
  end

  defp handle_info(msg, socket) when msg in [:dtq_refresh, :dtq_tick],
    do: {:halt, refresh(socket)}

  defp handle_info(_msg, socket), do: {:cont, socket}
end
