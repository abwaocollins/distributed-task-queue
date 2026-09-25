defmodule DistributedTaskQueueWeb.DeadLetterLive do
  @moduledoc "Jobs that exhausted their attempts, filterable by queue, with requeue and delete."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{Dashboard, Events}
  alias DistributedTaskQueueWeb.LiveRefresh

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dead letter", nav: :dead_letter, queue: nil, q: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(queue: blank_to_nil(params["queue"]), q: blank_to_nil(params["q"]))
     |> refresh()}
  end

  def refresh(socket) do
    filters = filters(socket.assigns)

    assign(socket,
      jobs: Dashboard.list_jobs(filters),
      total: Dashboard.count_jobs(filters),
      queue_names: Dashboard.queue_names()
    )
  end

  defp filters(%{queue: queue, q: q}), do: %{"status" => "dead", "queue" => queue, "q" => q}

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    query =
      params
      |> Map.take(~w(queue q))
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: ~p"/dead-letter?#{query}")}
  end

  def handle_event("requeue", %{"id" => id}, socket) do
    socket =
      case DistributedTaskQueue.requeue_dead_letter_job(id) do
        {:ok, job} ->
          Events.broadcast([:dtq, :console, :requeued], %{job_id: job.id})
          put_flash(socket, :info, "Job ##{job.id} requeued to #{job.queue_name}.")

        {:error, :not_found} ->
          put_flash(socket, :error, "Job ##{id} no longer exists.")

        {:error, :not_dead_letter} ->
          put_flash(socket, :error, "Job ##{id} is not in the dead-letter queue any more.")

        {:error, _changeset} ->
          put_flash(socket, :error, "Job ##{id} could not be requeued.")
      end

    {:noreply, LiveRefresh.refresh(socket)}
  end

  # Requeues exactly the jobs the current filter shows (every page of them),
  # not the whole dead-letter queue.
  def handle_event("requeue_matching", _params, socket) do
    filters = filters(socket.assigns)

    results =
      filters
      |> Dashboard.list_jobs_all()
      |> Enum.map(&DistributedTaskQueue.requeue_dead_letter_job(&1.id))

    ok = Enum.count(results, &match?({:ok, _}, &1))
    failed = length(results) - ok
    Events.broadcast([:dtq, :console, :requeued], %{count: ok})

    socket =
      socket
      |> put_flash(:info, "Requeued #{ok} #{pluralize(ok, "job", "jobs")}.")
      |> then(fn s ->
        if failed > 0,
          do:
            put_flash(
              s,
              :error,
              "#{failed} #{pluralize(failed, "job", "jobs")} could not be requeued."
            ),
          else: s
      end)

    {:noreply, LiveRefresh.refresh(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket =
      case DistributedTaskQueue.delete_job(id) do
        {:ok, job} ->
          Events.broadcast([:dtq, :console, :job_deleted], %{job_id: job.id})
          put_flash(socket, :info, "Job ##{job.id} deleted.")

        {:error, _} ->
          put_flash(socket, :error, "Job ##{id} could not be deleted.")
      end

    {:noreply, LiveRefresh.refresh(socket)}
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Dead letter">
      <:subtitle>
        Jobs that failed on every attempt. Requeue resets their attempts and runs them again.
      </:subtitle>
      <:actions>
        <.btn
          :if={@total > 0}
          id="requeue-matching"
          variant={:primary}
          phx-click="requeue_matching"
          phx-disable-with="Requeuing"
          data-confirm={"Requeue #{@total} #{pluralize(@total, "job", "jobs")}?"}
        >
          Requeue {if @queue || @q, do: "#{@total} shown", else: "all #{@total}"}
        </.btn>
      </:actions>
    </.page_header>

    <form
      id="dead-letter-filters"
      phx-change="filter"
      phx-submit="filter"
      class="mb-4 grid gap-3 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]"
    >
      <input
        type="search"
        name="filters[q]"
        value={@q}
        aria-label="Search"
        placeholder="Job id, worker or error text"
        phx-debounce="300"
        class="block w-full rounded-lg border-zinc-300 bg-white text-sm text-zinc-900 focus:border-zinc-400 focus:ring-0 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
      />
      <select
        name="filters[queue]"
        aria-label="Queue"
        class="block w-full rounded-lg border-zinc-300 bg-white text-sm text-zinc-900 focus:border-zinc-400 focus:ring-0 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
      >
        {Phoenix.HTML.Form.options_for_select([{"All queues", ""} | @queue_names], @queue)}
      </select>
    </form>

    <.empty_state :if={@jobs == [] and is_nil(@queue) and is_nil(@q)}>
      Empty. Jobs land here after exhausting their attempts.
    </.empty_state>
    <.empty_state :if={@jobs == [] and (@queue || @q)}>
      No dead-letter jobs match these filters.
    </.empty_state>

    <.surface :if={@jobs != []}>
      <table class="w-full text-left text-sm">
        <thead class={thead_class()}>
          <tr>
            <th class={th_class()}>Job</th>
            <th class={th_class()}>Worker</th>
            <th class={[th_class(), "w-1/2"]}>Last error</th>
            <th class={[th_class(), "text-right"]}>Discarded</th>
            <th class={th_class()}><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody class={tbody_class()}>
          <tr :for={job <- @jobs} id={"dead-#{job.id}"}>
            <td class={[td_class(), "whitespace-nowrap"]}>
              <.link navigate={~p"/jobs/#{job.id}"} class={[row_link_class(), "font-mono"]}>
                #{job.id}
              </.link>
              <span class="ml-1.5 text-zinc-500 dark:text-zinc-400">{job.queue_name}</span>
            </td>
            <td class={[td_class(), "font-mono text-xs text-zinc-600 dark:text-zinc-300"]}>
              {short_module(job.worker_module)}
            </td>
            <td class={[td_class(), "max-w-md"]}>
              <.error_text message={job.error_message || "No error recorded"} />
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right text-zinc-500 dark:text-zinc-400"]}>
              <.rel_time at={job.discarded_at} now={@now} />
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right"]}>
              <div class="flex justify-end gap-1.5">
                <.btn
                  size={:sm}
                  phx-click="requeue"
                  phx-value-id={job.id}
                  phx-disable-with="Requeuing"
                >
                  Requeue
                </.btn>
                <.btn
                  size={:sm}
                  variant={:danger}
                  phx-click="delete"
                  phx-value-id={job.id}
                  data-confirm={"Delete job ##{job.id}? It will not be retried."}
                >
                  Delete
                </.btn>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </.surface>
    <p :if={@total > length(@jobs)} class="mt-2 text-xs text-zinc-500 dark:text-zinc-400">
      Showing the {length(@jobs)} most recent of {@total}. Narrow with the filters above.
    </p>
    """
  end
end
