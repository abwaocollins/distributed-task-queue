defmodule DistributedTaskQueueWeb.JobLive do
  @moduledoc "One job: status, full error, payload, timeline, and requeue/delete."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{Dashboard, Events}
  alias DistributedTaskQueueWeb.LiveRefresh

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        {:ok, socket |> assign(nav: :jobs, job_id: id) |> refresh()}

      _ ->
        {:ok, socket |> put_flash(:error, "Invalid job id.") |> push_navigate(to: ~p"/jobs")}
    end
  end

  def refresh(%{assigns: %{job_id: id}} = socket) do
    job = Dashboard.get_job(id)
    assign(socket, job: job, page_title: "Job ##{id}")
  end

  def refresh(socket), do: socket

  @impl true
  def handle_event("requeue", _params, socket) do
    socket =
      case DistributedTaskQueue.requeue_dead_letter_job(socket.assigns.job_id) do
        {:ok, job} ->
          Events.broadcast([:dtq, :console, :requeued], %{job_id: job.id})
          put_flash(socket, :info, "Job ##{job.id} requeued.")

        {:error, :not_dead_letter} ->
          put_flash(socket, :error, "Only dead-letter jobs can be requeued.")

        {:error, _} ->
          put_flash(socket, :error, "Job could not be requeued.")
      end

    {:noreply, LiveRefresh.refresh(socket)}
  end

  def handle_event("delete", _params, socket) do
    case DistributedTaskQueue.delete_job(socket.assigns.job_id) do
      {:ok, job} ->
        Events.broadcast([:dtq, :console, :job_deleted], %{job_id: job.id})

        {:noreply,
         socket |> put_flash(:info, "Job ##{job.id} deleted.") |> push_navigate(to: ~p"/jobs")}

      {:error, :job_running} ->
        {:noreply, put_flash(socket, :error, "A running job cannot be deleted.")}

      {:error, :not_found} ->
        {:noreply,
         socket |> put_flash(:error, "Job no longer exists.") |> push_navigate(to: ~p"/jobs")}
    end
  end

  @impl true
  def render(%{job: nil} = assigns) do
    ~H"""
    <.page_header title={"Job ##{@job_id}"} />
    <.empty_state>
      This job does not exist or was deleted.
      <.link navigate={~p"/jobs"} class="font-medium underline">Back to jobs</.link>
    </.empty_state>
    """
  end

  def render(assigns) do
    ~H"""
    <.link
      navigate={~p"/jobs"}
      class="mb-4 inline-flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
    >
      <.icon name="hero-arrow-left-mini" class="h-4 w-4" /> Jobs
    </.link>

    <.page_header title={"Job ##{@job.id}"}>
      <:subtitle>
        {@job.worker_module} on
        <.link navigate={~p"/jobs?queue=#{@job.queue_name}"} class="underline">
          {@job.queue_name}
        </.link>
      </:subtitle>
      <:actions>
        <.job_status job={@job} />
        <.btn
          :if={@job.dead_letter}
          variant={:primary}
          phx-click="requeue"
          phx-disable-with="Requeuing"
        >
          Requeue
        </.btn>
        <.btn
          :if={@job.status != "started"}
          variant={:danger}
          phx-click="delete"
          data-confirm={"Delete job ##{@job.id}?"}
        >
          Delete
        </.btn>
      </:actions>
    </.page_header>

    <div class="space-y-8">
      <.callout
        :if={@job.error_message}
        id="job-error"
        kind={:error}
        title={error_title(@job)}
      >
        <pre class="mt-1 whitespace-pre-wrap break-words font-mono text-xs">{@job.error_message}</pre>
      </.callout>

      <div class="grid gap-8 lg:grid-cols-3">
        <.panel title="Details" class="min-w-0">
          <.surface>
            <dl class={[tbody_class(), "text-sm"]}>
              <.detail label="Attempts">
                <span class="font-mono">{@job.attempts} of {@job.max_attempts}</span>
              </.detail>
              <.detail label="Claimed by">
                <span class="font-mono text-xs">{node_of(@job.attempted_by) || "Not claimed"}</span>
              </.detail>
              <.detail :if={@job.cron_job_id} label="Cron job">
                <.link navigate={~p"/cron"} class="underline">#{@job.cron_job_id}</.link>
              </.detail>
            </dl>
          </.surface>
        </.panel>

        <.panel title="Timeline" class="min-w-0">
          <.surface>
            <dl class={[tbody_class(), "text-sm"]}>
              <.detail label="Created"><.rel_time at={@job.inserted_at} now={@now} /></.detail>
              <.detail :if={@job.scheduled_at} label="Scheduled for">
                <.rel_time at={@job.scheduled_at} now={@now} />
              </.detail>
              <.detail label="Started">
                <.rel_time at={@job.started_at} now={@now} empty="Not yet" />
              </.detail>
              <.detail :if={@job.next_retry_at} label="Next retry">
                <.rel_time at={@job.next_retry_at} now={@now} />
              </.detail>
              <.detail :if={@job.completed_at} label="Completed">
                <.rel_time at={@job.completed_at} now={@now} />
              </.detail>
              <.detail :if={@job.discarded_at} label="Discarded">
                <.rel_time at={@job.discarded_at} now={@now} />
              </.detail>
              <.detail label="Last update"><.rel_time at={@job.updated_at} now={@now} /></.detail>
            </dl>
          </.surface>
        </.panel>

        <.panel title="Payload" class="min-w-0">
          <.surface>
            <pre
              id="job-payload"
              class="overflow-x-auto p-4 font-mono text-xs text-zinc-800 dark:text-zinc-200"
            >{pretty_json(@job.payload)}</pre>
          </.surface>
        </.panel>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 px-4 py-3">
      <dt class="text-zinc-500 dark:text-zinc-400">{@label}</dt>
      <dd class="text-right text-zinc-900 dark:text-zinc-100">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp error_title(%{dead_letter: true}), do: "Failed on every attempt. This is the last error."
  defp error_title(%{status: "retryable"}), do: "Last attempt failed. It will be retried."
  defp error_title(_), do: "Last recorded error"
end
