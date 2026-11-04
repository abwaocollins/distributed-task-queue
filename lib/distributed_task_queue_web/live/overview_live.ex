defmodule DistributedTaskQueueWeb.OverviewLive do
  @moduledoc "Landing page: totals, anything that needs attention, recent failures, next cron runs."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.Dashboard
  alias DistributedTaskQueue.Demo.Receivers
  alias DistributedTaskQueue.Webhooks.Target
  alias DistributedTaskQueueWeb.DemoControls
  alias DistributedTaskQueueWeb.ScheduleText

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Overview", nav: :overview, node: Node.self())
     |> refresh()}
  end

  def refresh(socket) do
    queues = Dashboard.queue_summaries()
    demo? = Application.get_env(:distributed_task_queue, :demo_mode) == true

    assign(socket,
      demo_mode: demo?,
      receivers: if(demo?, do: Receivers.list(), else: []),
      demo_key: Application.get_env(:distributed_task_queue, :demo_api_key),
      totals: Dashboard.totals(),
      failures: Dashboard.recent_failures(),
      upcoming: Dashboard.upcoming_crons(),
      missing: Dashboard.crons_missing_queue(),
      orphan_queues: Enum.filter(queues, &(&1.running > 0 and not &1.manager_running)),
      stalled_queues: Enum.filter(queues, &(&1.paused and &1.pending + &1.retryable > 0))
    )
  end

  @impl true
  def handle_event("toggle_receiver", %{"name" => name}, socket) do
    # Only act in demo mode, and ignore names we do not know rather than crash.
    with true <- socket.assigns.demo_mode,
         %{online: online} <- Receivers.get(name) do
      Receivers.set_online(name, not online)
    end

    {:noreply, DistributedTaskQueueWeb.LiveRefresh.refresh(socket)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        attention_count:
          length(assigns.missing) + length(assigns.orphan_queues) +
            length(assigns.stalled_queues) + if(assigns.totals.dead > 0, do: 1, else: 0)
      )

    ~H"""
    <.page_header title="Overview">
      <:subtitle>
        Serving from <span class="font-mono text-zinc-700 dark:text-zinc-300">{@node}</span>
      </:subtitle>

      <:actions>
        <span
          id="live-status"
          class="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400"
          title="Updates arrive over the LiveView socket as jobs and cron ticks happen"
        >
          <span class={[
            "h-2 w-2 rounded-full",
            if(connected?(@socket), do: "bg-emerald-500", else: "bg-zinc-400")
          ]} /> {if connected?(@socket), do: "Live", else: "Connecting"}
        </span>
      </:actions>
    </.page_header>

    <div class="space-y-10">
      <.intro demo_mode={@demo_mode} demo_key={@demo_key} />
      <DemoControls.panel :if={@demo_mode} receivers={@receivers} />
      <nav
        aria-label="Job totals"
        class="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-zinc-200 bg-zinc-200 sm:grid-cols-5 dark:border-zinc-800 dark:bg-zinc-800"
      >
        <.stat label="Pending" value={@totals.pending} navigate={~p"/jobs?status=pending"} />
        <.stat label="Running" value={@totals.running} navigate={~p"/jobs?status=started"} />
        <.stat label="Retrying" value={@totals.retryable} navigate={~p"/jobs?status=retryable"} />
        <.stat label="Completed" value={@totals.completed} navigate={~p"/jobs?status=completed"} />
        <.stat
          label="Dead letter"
          value={@totals.dead}
          alert={@totals.dead > 0}
          navigate={~p"/dead-letter"}
          class="col-span-2 sm:col-span-1"
        />
      </nav>

      <.panel id="attention" title="Needs attention">
        <p :if={@attention_count == 0} class="text-sm text-zinc-500 dark:text-zinc-400">
          Nothing needs attention right now.
        </p>

        <div :if={@attention_count > 0} class="space-y-3">
          <.callout
            :for={{cron, queue} <- @missing}
            kind={:error}
            title={"Cron #{cron} targets queue #{queue}, which does not exist"}
          >
            It will not run until the queue is created.
            <.link navigate={~p"/queues/new?name=#{queue}"} class="font-medium underline">
              Create queue {queue}
            </.link>
          </.callout>

          <.callout
            :for={q <- @orphan_queues}
            kind={:warning}
            title={"#{q.running} #{pluralize(q.running, "job is", "jobs are")} marked running in #{q.name}, with no manager on this node"}
          >
            Another node may be running them, or they were orphaned when their node stopped.
            <.link navigate={~p"/jobs?queue=#{q.name}&status=started"} class="font-medium underline">
              View jobs
            </.link>
          </.callout>

          <.callout
            :for={q <- @stalled_queues}
            kind={:warning}
            title={"Queue #{q.name} is paused with #{q.pending + q.retryable} #{pluralize(q.pending + q.retryable, "job", "jobs")} waiting"}
          >
            <.link navigate={~p"/queues"} class="font-medium underline">Manage queues</.link>
          </.callout>

          <.callout
            :if={@totals.dead > 0}
            kind={:warning}
            title={"#{@totals.dead} #{pluralize(@totals.dead, "job has", "jobs have")} exhausted their attempts"}
          >
            <.link navigate={~p"/dead-letter"} class="font-medium underline">
              Review the dead-letter queue
            </.link>
          </.callout>
        </div>
      </.panel>

      <div class="grid gap-10 lg:grid-cols-5">
        <.panel id="recent-failures" title="Recent failures" class="min-w-0 lg:col-span-3">
          <:actions>
            <.btn size={:sm} navigate={~p"/jobs?errors=true"}>All errors</.btn>
          </:actions>

          <.empty_state :if={@failures == []}>No failed attempts recorded.</.empty_state>

          <.surface :if={@failures != []}>
            <ul class={tbody_class()}>
              <li :for={job <- @failures} id={"failure-#{job.id}"}>
                <.link
                  navigate={~p"/jobs/#{job.id}"}
                  class="block px-4 py-3 transition-colors hover:bg-zinc-50 dark:hover:bg-zinc-800/60"
                >
                  <div class="flex items-center justify-between gap-3">
                    <div class="flex min-w-0 items-center gap-2">
                      <span class="font-mono text-sm text-zinc-900 dark:text-zinc-100">
                        #{job.id}
                      </span>
                      <span class="truncate text-sm text-zinc-500 dark:text-zinc-400">
                        {short_module(job.worker_module)} on {job.queue_name}
                      </span>
                    </div>

                    <div class="flex shrink-0 items-center gap-3">
                      <.job_status job={job} />
                      <.rel_time
                        at={job.updated_at}
                        now={@now}
                        class="text-xs text-zinc-500 dark:text-zinc-400"
                      />
                    </div>
                  </div>
                  <.error_text message={job.error_message} class="mt-1.5" />
                </.link>
              </li>
            </ul>
          </.surface>
        </.panel>

        <.panel id="upcoming-crons" title="Next cron runs" class="min-w-0 lg:col-span-2">
          <:actions>
            <.btn size={:sm} navigate={~p"/cron"}>All cron jobs</.btn>
          </:actions>

          <.empty_state :if={@upcoming == []}>No enabled cron jobs.</.empty_state>

          <.surface :if={@upcoming != []}>
            <ul class={tbody_class()}>
              <li
                :for={cron <- @upcoming}
                class="flex items-center justify-between gap-3 px-4 py-3"
              >
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">
                    {cron.name}
                  </p>

                  <p class="text-xs text-zinc-500 dark:text-zinc-400" title={schedule(cron)}>
                    {ScheduleText.describe(cron)}
                  </p>
                </div>

                <.rel_time
                  at={cron.next_run_at}
                  now={@now}
                  class="shrink-0 text-sm text-zinc-900 dark:text-zinc-100"
                />
              </li>
            </ul>
          </.surface>
        </.panel>
      </div>
    </div>
    """
  end

  @repo_url "https://github.com/abwaocollins/distributed-task-queue"

  attr :demo_mode, :boolean, required: true
  attr :demo_key, :string, default: nil

  # Written for someone who cannot read code. Hidden for good once dismissed
  # (see the DismissOnce hook).
  defp intro(assigns) do
    assigns =
      assign(assigns, :repo_url, @repo_url)

    ~H"""
    <section
      id="demo-intro"
      phx-hook="DismissOnce"
      class="rounded-xl border border-zinc-200 bg-white px-5 py-4 text-sm text-zinc-700 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300"
    >
      <div class="flex items-start justify-between gap-4">
        <p class="font-medium text-zinc-900 dark:text-zinc-100">
          This is a job service: other apps hand it work — like "call this web address in 10 minutes" — and it makes sure the work actually happens, even when things break.
        </p>

        <button
          type="button"
          data-dismiss
          class="shrink-0 text-xs text-zinc-500 underline hover:text-zinc-700 dark:text-zinc-400"
        >
          Dismiss
        </button>
      </div>

      <div :if={@demo_mode} class="mt-3">
        <p class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
          Try this
        </p>

        <ol class="mt-1 list-decimal space-y-1 pl-5">
          <li>Take the Warehouse offline below.</li>

          <li>
            Open <.link navigate={~p"/jobs"} class="underline">Jobs</.link>
            and watch its deliveries fail and retry, waiting a little longer each time.
          </li>

          <li>
            Bring it back online — the backlog clears; anything that ran out of tries is in <.link
              navigate={~p"/dead-letter"}
              class="underline"
            >Dead letter</.link>,
            where you can press Requeue.
          </li>
        </ol>
      </div>

      <div :if={@demo_key} class="mt-3 space-y-1">
        <p>
          Want to send it work yourself? Use this demo key:
          <code class="rounded bg-zinc-100 px-1 py-0.5 font-mono text-xs dark:bg-zinc-800">
            {@demo_key}
          </code>
        </p>
        <pre class="overflow-x-auto rounded-lg bg-zinc-100 p-3 font-mono text-xs dark:bg-zinc-800"><code>{curl_example(@demo_key)}</code></pre>
      </div>

      <p class="mt-3 text-xs text-zinc-500 dark:text-zinc-400">
        <a href={@repo_url} class="underline" target="_blank" rel="noopener">GitHub repo</a>
        ·
        <a
          href={@repo_url <> "/tree/main/docs/engineering"}
          class="underline"
          target="_blank"
          rel="noopener"
        >
          Engineering writeups
        </a>
      </p>
    </section>
    """
  end

  defp curl_example(key) do
    body = Jason.encode!(%{url: Target.demo_receiver_url("warehouse"), delay_seconds: 60})

    Enum.join(
      [
        "curl -X POST #{DistributedTaskQueueWeb.Endpoint.url()}/api/webhooks",
        ~s(  -H "authorization: Bearer #{key}"),
        ~s(  -H "content-type: application/json"),
        "  -d '#{body}'"
      ],
      " \\\n"
    )
  end
end
