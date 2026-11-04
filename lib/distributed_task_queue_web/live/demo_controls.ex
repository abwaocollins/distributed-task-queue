defmodule DistributedTaskQueueWeb.DemoControls do
  @moduledoc """
  The Online/Offline switches for the demo receivers, shown on the Overview in
  demo mode so a visitor can break a service and watch the retries happen.
  """
  use Phoenix.Component

  import DistributedTaskQueueWeb.ConsoleComponents, except: [panel: 1]

  alias DistributedTaskQueueWeb.ConsoleComponents, as: Console

  attr :receivers, :list, required: true

  def panel(assigns) do
    ~H"""
    <Console.panel id="demo-controls" title="Demo controls">
      <.surface>
        <ul class={tbody_class()}>
          <li
            :for={r <- @receivers}
            id={"receiver-#{r.name}"}
            class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
          >
            <div class="min-w-0">
              <p class="text-sm font-medium capitalize text-zinc-900 dark:text-zinc-100">{r.name}</p>

              <p class={[
                "text-xs",
                if(r.online,
                  do: "text-emerald-700 dark:text-emerald-300",
                  else: "text-amber-700 dark:text-amber-300"
                )
              ]}>
                {status_text(r)}
              </p>
            </div>

            <.btn size={:sm} phx-click="toggle_receiver" phx-value-name={r.name}>
              {if r.online, do: "Take offline", else: "Bring online"}
            </.btn>
          </li>
        </ul>
      </.surface>
    </Console.panel>
    """
  end

  defp status_text(%{online: true}), do: "Online"

  defp status_text(%{offline_until: nil}), do: "Offline"

  defp status_text(%{offline_until: until}),
    do: "Offline — back online at #{hhmm(until)} UTC"
end
