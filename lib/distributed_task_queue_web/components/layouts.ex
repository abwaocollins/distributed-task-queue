defmodule DistributedTaskQueueWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use DistributedTaskQueueWeb, :controller` and
  `use DistributedTaskQueueWeb, :live_view`.
  """
  use DistributedTaskQueueWeb, :html

  embed_templates "layouts/*"

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "group flex shrink-0 items-center gap-1.5 rounded-md px-2.5 py-1.5 font-medium transition-colors",
        if(@active,
          do: "bg-accent-50 text-accent-700 dark:bg-accent-400/10 dark:text-accent-300",
          else:
            "text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-800/60 dark:hover:text-zinc-100"
        )
      ]}
    >
      <.icon
        name={@icon}
        class={
          if(@active,
            do: "h-4 w-4 text-accent-600 dark:text-accent-300",
            else: "h-4 w-4 text-zinc-400 group-hover:text-zinc-600 dark:text-zinc-500"
          )
        }
      />
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
