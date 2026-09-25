defmodule DistributedTaskQueueWeb.QueuesLive do
  @moduledoc "Queue list with create, edit, pause/resume and delete."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{Dashboard, Events, Queue}
  alias DistributedTaskQueueWeb.LiveRefresh

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Queues", nav: :queues) |> refresh()}
  end

  def refresh(socket), do: assign(socket, queues: Dashboard.queue_summaries())

  @impl true
  def handle_params(params, _url, socket), do: {:noreply, apply_action(socket, params)}

  defp apply_action(%{assigns: %{live_action: :new}} = socket, params) do
    changeset = Queue.changeset(%Queue{}, %{"name" => params["name"]})
    assign(socket, editing: %Queue{}, form: to_form(changeset, as: :queue))
  end

  defp apply_action(%{assigns: %{live_action: :edit}} = socket, %{"name" => name}) do
    case DistributedTaskQueue.get_queue(name) do
      nil ->
        socket
        |> put_flash(:error, "Queue #{name} does not exist.")
        |> push_patch(to: ~p"/queues")

      queue ->
        assign(socket,
          editing: queue,
          form: to_form(Queue.update_changeset(queue, %{}), as: :queue)
        )
    end
  end

  defp apply_action(socket, _params), do: assign(socket, editing: nil, form: nil)

  @impl true
  def handle_event("validate", %{"queue" => params}, socket) do
    changeset =
      socket.assigns.editing
      |> changeset_for(socket.assigns.live_action, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :queue))}
  end

  def handle_event("save", %{"queue" => params}, %{assigns: %{live_action: :new}} = socket) do
    case DistributedTaskQueue.add_queue(params) do
      {:ok, queue} -> {:noreply, saved(socket, "Queue #{queue.name} created.")}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset, as: :queue))}
    end
  end

  def handle_event("save", %{"queue" => params}, %{assigns: %{live_action: :edit}} = socket) do
    case DistributedTaskQueue.update_queue(socket.assigns.editing, params) do
      {:ok, queue} -> {:noreply, saved(socket, "Queue #{queue.name} updated.")}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset, as: :queue))}
    end
  end

  def handle_event("pause", %{"name" => name}, socket),
    do: {:noreply, run(socket, name, &DistributedTaskQueue.pause_queue/1, "paused")}

  def handle_event("resume", %{"name" => name}, socket),
    do: {:noreply, run(socket, name, &DistributedTaskQueue.resume_queue/1, "resumed")}

  def handle_event("delete", %{"name" => name}, socket),
    do: {:noreply, run(socket, name, &DistributedTaskQueue.delete_queue/1, "deleted")}

  defp changeset_for(queue, :new, params), do: Queue.changeset(queue, params)
  defp changeset_for(queue, :edit, params), do: Queue.update_changeset(queue, params)

  defp saved(socket, message) do
    Events.broadcast([:dtq, :console, :queue_changed])

    socket
    |> put_flash(:info, message)
    |> push_patch(to: ~p"/queues")
    |> LiveRefresh.refresh()
  end

  defp run(socket, name, fun, verb) do
    socket =
      case fun.(name) do
        {:ok, _queue} ->
          Events.broadcast([:dtq, :console, :queue_changed], %{queue_name: name})
          put_flash(socket, :info, "Queue #{name} #{verb}.")

        {:error, :queue_not_found} ->
          put_flash(socket, :error, "Queue #{name} no longer exists.")

        {:error, _changeset} ->
          put_flash(socket, :error, "Queue #{name} could not be #{verb}.")
      end

    LiveRefresh.refresh(socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Queues">
      <:subtitle>
        Each queue runs up to its concurrency limit of jobs at once, per node.
      </:subtitle>
      <:actions>
        <.btn variant={:primary} patch={~p"/queues/new"} id="new-queue">
          <.icon name="hero-plus-mini" class="h-4 w-4" /> New queue
        </.btn>
      </:actions>
    </.page_header>

    <.empty_state :if={@queues == []}>
      No queues yet. Create one to start enqueueing jobs.
    </.empty_state>

    <.surface :if={@queues != []}>
      <table class="w-full text-left text-sm">
        <thead class={thead_class()}>
          <tr>
            <th class={th_class()}>Queue</th>
            <th class={th_class()}>State</th>
            <th class={[th_class(), "text-right"]}>Pending</th>
            <th class={[th_class(), "text-right"]}>Running</th>
            <th class={[th_class(), "text-right"]}>Retrying</th>
            <th class={[th_class(), "text-right"]}>Completed</th>
            <th class={[th_class(), "text-right"]}>Dead</th>
            <th class={th_class()}><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody class={tbody_class()}>
          <tr :for={q <- @queues} id={"queue-#{q.name}"}>
            <td class={td_class()}>
              <.link navigate={~p"/jobs?queue=#{q.name}"} class={row_link_class()}>
                {q.name}
              </.link>
              <p :if={q.queue.description} class="text-xs text-zinc-500 dark:text-zinc-400">
                {q.queue.description}
              </p>
            </td>
            <td class={td_class()}><.queue_state summary={q} /></td>
            <td class={num_class()}>{q.pending}</td>
            <td
              class={[num_class(), orphaned?(q) && "text-amber-700 dark:text-amber-300"]}
              title={
                orphaned?(q) &&
                  "Marked running, but this node has no manager for the queue. Another node may be running these jobs, or they were orphaned."
              }
            >
              {q.running}<span class="text-zinc-400 dark:text-zinc-500"> / {q.concurrency}</span>
            </td>
            <td class={num_class()}>{q.retryable}</td>
            <td class={num_class()}>{q.completed}</td>
            <td class={[num_class(), q.dead > 0 && "text-rose-600 dark:text-rose-400"]}>
              <.link
                :if={q.dead > 0}
                navigate={~p"/dead-letter?queue=#{q.name}"}
                class="hover:underline"
              >
                {q.dead}
              </.link>
              <span :if={q.dead == 0}>0</span>
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right"]}>
              <div class="flex justify-end gap-1.5">
                <.btn
                  :if={!q.paused}
                  size={:sm}
                  phx-click="pause"
                  phx-value-name={q.name}
                  phx-disable-with="Pausing"
                >
                  Pause
                </.btn>
                <.btn
                  :if={q.paused}
                  size={:sm}
                  phx-click="resume"
                  phx-value-name={q.name}
                  phx-disable-with="Resuming"
                >
                  Resume
                </.btn>
                <.btn size={:sm} patch={~p"/queues/#{q.name}/edit"} id={"edit-#{q.name}"}>
                  Edit
                </.btn>
                <.btn
                  size={:sm}
                  variant={:danger}
                  phx-click="delete"
                  phx-value-name={q.name}
                  phx-disable-with="Deleting"
                  data-confirm={"Delete queue #{q.name}? Its #{q.pending + q.running + q.retryable + q.completed + q.dead} jobs are deleted and cron jobs pointing at it are disabled."}
                >
                  Delete
                </.btn>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </.surface>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="queue-modal"
      show
      on_cancel={JS.patch(~p"/queues")}
    >
      <h2 id="queue-modal-title" class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">
        {if @live_action == :new, do: "New queue", else: "Edit #{@editing.name}"}
      </h2>
      <.simple_form for={@form} id="queue-form" phx-change="validate" phx-submit="save">
        <.input
          :if={@live_action == :new}
          field={@form[:name]}
          label="Name"
          autocomplete="off"
          phx-debounce="300"
        />
        <.input field={@form[:description]} label="Description" phx-debounce="300" />
        <.input
          field={@form[:max_concurrent_jobs]}
          type="number"
          min="1"
          label="Concurrency"
          phx-debounce="300"
        />
        <p :if={@live_action == :edit} class="text-xs text-zinc-500 dark:text-zinc-400">
          A new concurrency applies the next time the queue's manager starts. Restarting it now
          would kill jobs in flight.
        </p>
        <:actions>
          <.btn patch={~p"/queues"}>Cancel</.btn>
          <.btn variant={:primary} type="submit" phx-disable-with="Saving">Save</.btn>
        </:actions>
      </.simple_form>
    </.modal>
    """
  end

  defp orphaned?(q), do: q.running > 0 and not q.manager_running
end
