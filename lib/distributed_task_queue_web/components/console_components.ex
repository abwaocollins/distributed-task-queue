defmodule DistributedTaskQueueWeb.ConsoleComponents do
  @moduledoc """
  Building blocks and formatting helpers shared by the console pages.

  Visual rules: zinc neutrals, one violet `accent` for interaction (primary
  button, active nav, focus, selection), other colour only where it carries
  state (job status, errors, warnings), one radius scale (`rounded-lg` controls,
  `rounded-xl` panels), tabular figures everywhere: mono for IDs and table
  numbers, sans for headline KPIs. Statuses are dot pills; depth comes from
  hairlines plus the soft `shadow-card` in light mode, hairlines only in dark.
  """
  use Phoenix.Component

  import DistributedTaskQueueWeb.CoreComponents, only: [icon: 1]

  ## Layout

  attr :title, :string, required: true
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="mb-8 flex flex-wrap items-end justify-between gap-4">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          {@title}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={@class}>
      <div :if={@title} class="mb-3 flex min-h-8 items-center justify-between gap-4">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">{@title}</h2>
        {render_slot(@actions)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "Bordered surface. Tables inside scroll horizontally on narrow screens."
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def surface(assigns) do
    ~H"""
    <div class={[
      "overflow-x-auto rounded-xl border border-zinc-200/80 bg-white shadow-card dark:border-zinc-800 dark:bg-zinc-900/60 dark:shadow-none",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-3 rounded-xl border border-dashed border-zinc-300 bg-white/50 px-4 py-10 text-center text-sm text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900/30 dark:text-zinc-400">
      <span class="grid h-9 w-9 place-items-center rounded-lg bg-zinc-100 text-zinc-400 ring-1 ring-inset ring-zinc-200 dark:bg-zinc-800 dark:text-zinc-500 dark:ring-zinc-700">
        <.icon name="hero-inbox-mini" class="h-5 w-5" />
      </span>
      <div>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :kind, :atom, values: [:warning, :error], default: :warning
  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block

  def callout(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class={[
        "flex gap-3 rounded-xl border px-4 py-3 text-sm",
        @kind == :warning &&
          "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-400/20 dark:bg-amber-400/10 dark:text-amber-200",
        @kind == :error &&
          "border-rose-200 bg-rose-50 text-rose-900 dark:border-rose-400/20 dark:bg-rose-400/10 dark:text-rose-200"
      ]}
    >
      <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 h-5 w-5 flex-none" />
      <div class="min-w-0">
        <p class="font-medium">{@title}</p>
        <div :if={@inner_block != []} class="mt-1 opacity-90">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  ## Tables

  def thead_class,
    do:
      "border-b border-zinc-200/80 bg-zinc-50/80 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400"

  def th_class, do: "px-4 py-2.5 font-medium whitespace-nowrap"

  def tbody_class,
    do:
      "divide-y divide-zinc-100 dark:divide-zinc-800 [&>tr]:transition-colors [&>tr:hover]:bg-zinc-50/70 dark:[&>tr:hover]:bg-zinc-800/30"

  def td_class, do: "px-4 py-3"

  def num_class,
    do: "px-4 py-3 text-right font-mono tabular-nums text-zinc-700 dark:text-zinc-300"

  def row_link_class,
    do: "font-medium text-zinc-900 hover:underline dark:text-zinc-100"

  ## Buttons

  @doc """
  Button or link styled as a button. Pass `navigate`/`patch` to render a link.
  """
  attr :variant, :atom, values: [:primary, :secondary, :danger], default: :secondary
  attr :size, :atom, values: [:sm, :md], default: :md
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :class, :any, default: nil
  attr :type, :string, default: "button"
  attr :rest, :global, include: ~w(disabled phx-click phx-value-id phx-value-name
                                   phx-disable-with data-confirm form)
  slot :inner_block, required: true

  def btn(%{navigate: nil, patch: nil} = assigns) do
    ~H"""
    <button type={@type} class={[btn_class(@variant, @size), @class]} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  def btn(assigns) do
    ~H"""
    <.link navigate={@navigate} patch={@patch} class={[btn_class(@variant, @size), @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def btn_class(variant, size) do
    [
      "inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-lg font-medium",
      "transition-colors active:translate-y-px disabled:pointer-events-none disabled:opacity-50",
      "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-500",
      size == :sm && "px-2.5 py-1 text-xs",
      size == :md && "px-3 py-1.5 text-sm",
      variant == :primary &&
        "bg-accent-600 text-white shadow-sm shadow-accent-700/25 ring-1 ring-inset ring-white/10 hover:bg-accent-700 dark:bg-accent-400 dark:text-zinc-950 dark:shadow-none dark:hover:bg-accent-300",
      variant == :secondary &&
        "border border-zinc-200 bg-white text-zinc-700 shadow-card hover:border-zinc-300 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:shadow-none dark:hover:bg-zinc-800",
      variant == :danger &&
        "border border-rose-200 bg-white text-rose-700 shadow-card hover:border-rose-300 hover:bg-rose-50 dark:border-rose-400/30 dark:bg-zinc-900 dark:text-rose-300 dark:shadow-none dark:hover:bg-rose-400/10"
    ]
  end

  ## Badges

  def badge_class,
    do: "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium whitespace-nowrap"

  @doc "Badge with a leading dot in the text colour, for states rather than tags."
  def pill_class,
    do: [
      "inline-flex items-center gap-1.5 rounded-full py-0.5 pl-2 pr-2.5 text-xs font-medium whitespace-nowrap ring-1 ring-inset ring-black/5 dark:ring-white/10",
      "before:h-1.5 before:w-1.5 before:rounded-full before:bg-current before:content-['']",
      "motion-reduce:before:animate-none"
    ]

  attr :job, :map, required: true

  def job_status(assigns) do
    ~H"""
    <span
      class={[pill_class(), status_tone(@job), @job.status == "started" && "before:animate-pulse"]}
      title={status_hint(@job)}
    >
      {status_label(@job)}
    </span>
    """
  end

  @doc "A plain-English sentence for the badge tooltip, for readers new to job queues."
  @spec status_hint(map()) :: String.t()
  def status_hint(%{dead_letter: true} = job) do
    n = Map.get(job, :attempts) || 0
    "Gave up after #{n} #{pluralize(n, "try", "tries")}"
  end

  def status_hint(%{status: "pending"}), do: "Waiting its turn"
  def status_hint(%{status: "started"}), do: "Running now"
  def status_hint(%{status: "completed"}), do: "Done"

  def status_hint(%{status: "retryable"} = job) do
    case Map.get(job, :next_retry_at) do
      nil -> "Failed — will try again soon"
      at -> "Failed — will try again at #{hhmm(at)} UTC"
    end
  end

  def status_hint(%{status: status}) when status in ["discarded", "dead"],
    do: "Gave up — it ran out of tries"

  def status_hint(%{status: "cancelled"}), do: "Stopped by hand — retry to run it again"

  def status_hint(_), do: ""

  @doc "HH:MM in UTC."
  def hhmm(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  def hhmm(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%H:%M")

  def status_label(%{dead_letter: true}), do: "Dead letter"
  def status_label(%{status: status}), do: status_name(status)

  def status_name("started"), do: "Running"
  def status_name("retryable"), do: "Retrying"
  def status_name("discarded"), do: "Discarded"
  def status_name("dead"), do: "Dead letter"
  def status_name("cancelled"), do: "Stopped"
  def status_name(status), do: String.capitalize(status)

  defp status_tone(%{dead_letter: true}), do: tone(:rose)
  defp status_tone(%{status: "started"}), do: tone(:sky)
  defp status_tone(%{status: "completed"}), do: tone(:emerald)
  defp status_tone(%{status: "retryable"}), do: tone(:amber)
  defp status_tone(%{status: "discarded"}), do: tone(:rose)
  defp status_tone(_), do: tone(:zinc)

  def tone(:rose), do: "bg-rose-50 text-rose-700 dark:bg-rose-400/10 dark:text-rose-300"
  def tone(:sky), do: "bg-sky-50 text-sky-800 dark:bg-sky-400/10 dark:text-sky-300"

  def tone(:emerald),
    do: "bg-emerald-50 text-emerald-800 dark:bg-emerald-400/10 dark:text-emerald-300"

  def tone(:amber), do: "bg-amber-50 text-amber-800 dark:bg-amber-400/10 dark:text-amber-300"
  def tone(:zinc), do: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"

  attr :summary, :map, required: true

  def queue_state(assigns) do
    ~H"""
    <span :if={@summary.paused} class={[pill_class(), tone(:amber)]}>Paused</span>
    <span
      :if={!@summary.paused && @summary.manager_running}
      class={[pill_class(), tone(:sky), "before:animate-pulse"]}
    >
      Running
    </span>
    <span
      :if={!@summary.paused && !@summary.manager_running}
      class={[pill_class(), tone(:zinc)]}
      title="No manager on this node. Managers stop once their queue drains and restart when work arrives."
    >
      Idle
    </span>
    """
  end

  @doc "Truncated error with the full text on hover. Renders nothing without one."
  attr :message, :string, default: nil
  attr :class, :any, default: nil

  def error_text(assigns) do
    ~H"""
    <p
      :if={@message}
      class={["flex min-w-0 items-center gap-1.5 text-rose-700 dark:text-rose-300", @class]}
      title={@message}
    >
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 flex-none" />
      <span class="truncate font-mono text-xs">{@message}</span>
    </p>
    """
  end

  ## Stats

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :navigate, :string, required: true
  attr :alert, :boolean, default: false
  attr :dot, :string, default: "bg-zinc-400", doc: "status colour, matching the job pill"
  attr :class, :any, default: nil

  def stat(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "group relative block bg-white px-5 py-4 transition-colors hover:bg-zinc-50/80 dark:bg-zinc-900 dark:hover:bg-zinc-800/50",
        @class
      ]}
    >
      <span class="flex items-center gap-2 text-xs font-medium text-zinc-500 dark:text-zinc-400">
        <span class={["h-1.5 w-1.5 rounded-full", @dot]} />
        {@label}
        <.icon
          name="hero-arrow-up-right-micro"
          class="ml-auto h-3.5 w-3.5 text-zinc-400 opacity-0 transition-opacity group-hover:opacity-100"
        />
      </span>
      <span class={[
        "mt-2 block text-3xl font-semibold tracking-tight tabular-nums",
        if(@alert, do: "text-rose-600 dark:text-rose-400", else: "text-zinc-900 dark:text-zinc-50")
      ]}>
        {delimit(@value)}
      </span>
    </.link>
    """
  end

  @doc "Integer with thousands separators: 12345 -> \"12,345\"."
  def delimit(n) when is_integer(n) and n < 0, do: "-" <> delimit(-n)

  def delimit(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  ## Formatting

  def short_module(nil), do: "unknown"
  def short_module(module), do: module |> String.split(".") |> List.last()

  # attempted_by is "node:queue".
  def node_of(nil), do: nil
  def node_of(attempted_by), do: attempted_by |> String.split(":") |> hd()

  def schedule(%{cron_expression: expr}) when is_binary(expr), do: expr
  def schedule(%{interval_seconds: s}) when is_integer(s), do: "every #{duration(s)}"
  def schedule(_), do: "unscheduled"

  def duration(s) when rem(s, 3600) == 0, do: "#{div(s, 3600)}h"
  def duration(s) when rem(s, 60) == 0, do: "#{div(s, 60)}m"
  def duration(s), do: "#{s}s"

  attr :at, :any, required: true
  attr :now, :any, required: true
  attr :empty, :string, default: "never"
  attr :class, :any, default: nil

  def rel_time(assigns) do
    ~H"""
    <span :if={is_nil(@at)} class={@class}>{@empty}</span>
    <time :if={@at} datetime={iso(@at)} title={iso(@at)} class={@class}>
      {relative(@at, @now)}
    </time>
    """
  end

  def iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  def relative(nil, _now), do: "never"

  def relative(%NaiveDateTime{} = at, now),
    do: at |> DateTime.from_naive!("Etc/UTC") |> relative(now)

  def relative(%DateTime{} = at, now) do
    diff = DateTime.diff(at, now, :second)

    cond do
      abs(diff) < 5 -> "just now"
      diff > 0 -> "in #{span(diff)}"
      true -> "#{span(-diff)} ago"
    end
  end

  defp span(s) when s < 60, do: "#{s}s"
  defp span(s) when s < 3600, do: "#{div(s, 60)}m"
  defp span(s) when s < 86_400, do: "#{div(s, 3600)}h"
  defp span(s), do: "#{div(s, 86_400)}d"

  def pretty_json(nil), do: "null"
  def pretty_json(value), do: Jason.encode!(value, pretty: true)

  def pluralize(1, one, _many), do: one
  def pluralize(_, _one, many), do: many
end
