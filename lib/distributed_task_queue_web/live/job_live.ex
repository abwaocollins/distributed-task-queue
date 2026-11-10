defmodule DistributedTaskQueueWeb.JobLive do
  @moduledoc "One job: status, full error, payload, timeline, and retry/stop/delete."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{Dashboard, Events, Webhooks}
  alias DistributedTaskQueue.Webhooks.Request
  alias DistributedTaskQueue.Workers.Webhook
  alias DistributedTaskQueueWeb.{JobActions, LiveRefresh}

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
    # Loaded here so the attempts table follows retries as they happen.
    deliveries = if webhook?(job), do: Webhooks.list_deliveries(id), else: []
    assign(socket, job: job, deliveries: deliveries, page_title: "Job ##{id}")
  end

  def refresh(socket), do: socket

  @impl true
  def handle_event("retry", _params, socket),
    do: {:noreply, socket |> JobActions.retry(socket.assigns.job_id) |> LiveRefresh.refresh()}

  def handle_event("stop", _params, socket),
    do: {:noreply, socket |> JobActions.stop(socket.assigns.job_id) |> LiveRefresh.refresh()}

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
          :if={JobActions.retryable?(@job)}
          variant={:primary}
          phx-click="retry"
          phx-disable-with="Queuing"
        >
          {JobActions.retry_label(@job)}
        </.btn>
        <.btn
          :if={JobActions.stoppable?(@job)}
          phx-click="stop"
          phx-disable-with="Stopping"
          data-confirm={"Stop job ##{@job.id}?"}
        >
          Stop
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

        <.panel :if={webhook?(@job)} title="Request" class="min-w-0">
          <.surface>
            <dl id="job-request" class={[tbody_class(), "text-sm"]}>
              <.detail label="Method">
                <span class="font-mono">{request_method(@job.payload)}</span>
              </.detail>
              <.detail label="URL">
                <span class="break-all font-mono text-xs">{@job.payload["url"]}</span>
              </.detail>
              <div
                :for={{name, value} <- request_headers(@job.payload)}
                class="flex justify-between gap-4 px-4 py-2 font-mono text-xs"
              >
                <dt class="text-zinc-500 dark:text-zinc-400">{name}</dt>
                <dd class="break-all text-right">{value}</dd>
              </div>
            </dl>
            <pre
              :if={request_body(@job.payload)}
              id="job-request-body"
              class="overflow-x-auto border-t border-zinc-100 p-4 font-mono text-xs text-zinc-800 dark:border-zinc-800 dark:text-zinc-200"
            >{request_body(@job.payload)}</pre>
          </.surface>
        </.panel>

        <%!-- A webhook payload can hold credential headers, so it is only ever
             shown through the redacted Request panel above. --%>
        <.panel :if={!webhook?(@job)} title="Payload" class="min-w-0">
          <.surface>
            <pre
              id="job-payload"
              class="overflow-x-auto p-4 font-mono text-xs text-zinc-800 dark:text-zinc-200"
            >{pretty_json(@job.payload)}</pre>
          </.surface>
        </.panel>
      </div>

      <.panel :if={webhook?(@job)} title="Delivery attempts">
        <.empty_state :if={@deliveries == []}>No delivery attempts yet.</.empty_state>
        <.surface :if={@deliveries != []}>
          <table id="deliveries" class="w-full text-left text-sm">
            <thead class={thead_class()}>
              <tr>
                <th class={th_class()}>#</th>
                <th class={th_class()}>When</th>
                <th class={th_class()}>Result</th>
                <th class={th_class()}>Took</th>
                <th class={th_class()}>Response</th>
              </tr>
            </thead>
            <tbody class={tbody_class()}>
              <tr :for={d <- @deliveries} id={"delivery-#{d.number}"} class="align-top">
                <td class={[td_class(), "font-mono"]}>{d.number}</td>
                <td class={td_class()}><.rel_time at={d.inserted_at} now={@now} /></td>
                <td class={td_class()}>{result_text(d)}</td>
                <td class={[td_class(), "font-mono"]}>{d.duration_ms && "#{d.duration_ms} ms"}</td>
                <td class={td_class()}>
                  <details :if={d.response_body not in [nil, ""]}>
                    <summary class="cursor-pointer text-zinc-500 dark:text-zinc-400">Show</summary>
                    <pre class="mt-2 max-w-xl overflow-x-auto whitespace-pre-wrap break-words font-mono text-xs">{d.response_body}</pre>
                  </details>
                </td>
              </tr>
            </tbody>
          </table>
        </.surface>
      </.panel>
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

  defp webhook?(%{worker_module: module}), do: module == Webhook.module_name()
  defp webhook?(_), do: false

  defp request_method(payload), do: String.upcase(to_string(payload["method"] || "POST"))

  # Credential values are masked here, never in the stored payload.
  defp request_headers(payload) do
    case payload["headers"] do
      headers when is_map(headers) -> headers |> Request.redact_headers() |> Enum.sort()
      _ -> []
    end
  end

  defp request_body(payload) do
    case payload["body"] do
      body when body in [nil, ""] ->
        nil

      body when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) -> pretty_json(decoded)
          _ -> body
        end

      other ->
        pretty_json(other)
    end
  end

  defp result_text(%{status_code: code}) when is_integer(code) do
    case reason_phrase(code) do
      nil -> to_string(code)
      phrase -> "#{code} #{phrase}"
    end
  end

  defp result_text(%{error: error}), do: error || "No result recorded"

  defp reason_phrase(code) do
    Plug.Conn.Status.reason_phrase(code)
  rescue
    _ -> nil
  end

  # A discard doesn't count as an attempt, so a job that used them all up was
  # discarded on attempt number max_attempts, i.e. attempts + 1. Anything
  # earlier was a permanent failure that skipped the remaining retries.
  defp error_title(%{dead_letter: true, attempts: attempts, max_attempts: max})
       when attempts + 1 < max,
       do: "Failed permanently — retrying would not help."

  defp error_title(%{dead_letter: true}), do: "Failed on every attempt. This is the last error."
  defp error_title(%{status: "retryable"}), do: "Last attempt failed. It will be retried."
  defp error_title(_), do: "Last recorded error"
end
