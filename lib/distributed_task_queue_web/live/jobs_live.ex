defmodule DistributedTaskQueueWeb.JobsLive do
  @moduledoc """
  Filterable, paginated job list with a create form. Filters live in the URL,
  so a filtered view can be bookmarked or linked to from other pages.
  """
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{Dashboard, Events, Job, Webhooks}
  alias DistributedTaskQueue.Webhooks.{Request, Target}
  alias DistributedTaskQueueWeb.{CoreComponents, JsonField, LiveRefresh, WebhookFields, WebhookForm}

  @filter_keys ~w(queue status errors q)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Jobs",
       nav: :jobs,
       filters: %{},
       page: 1,
       queue_names: Dashboard.queue_names(),
       workers: Dashboard.known_workers()
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filters = params |> Map.take(@filter_keys) |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    socket
    |> assign(filters: filters, page: parse_page(params["page"]))
    |> apply_action(socket.assigns.live_action)
    |> refresh()
    |> then(&{:noreply, &1})
  end

  def refresh(socket) do
    %{filters: filters, page: page} = socket.assigns

    assign(socket,
      jobs: Dashboard.list_jobs(filters, page),
      total: Dashboard.count_jobs(filters),
      queue_names: Dashboard.queue_names()
    )
  end

  defp apply_action(socket, :new) do
    params = %{"queue_name" => socket.assigns.filters["queue"], "max_attempts" => 3}
    targets = Webhooks.targets()

    assign(socket,
      kind: "webhook",
      form: to_form(Job.changeset(%Job{}, params), as: :job),
      payload_text: "{}",
      targets: targets,
      header_rows: [],
      wh_form: webhook_form(webhook_defaults(socket, targets), [])
    )
  end

  defp apply_action(socket, _index), do: assign(socket, form: nil)

  defp webhook_defaults(socket, targets) do
    queue = if "webhooks" in socket.assigns.queue_names, do: "webhooks", else: ""

    %{
      "kind" => "webhook",
      "url" => if(targets == :demo_receivers, do: first_receiver_url(), else: ""),
      "method" => "POST",
      "body" => "",
      "queue_name" => queue,
      "max_attempts" => "5",
      "when" => "now",
      "in_minutes" => "10",
      "run_at" => ""
    }
  end

  defp first_receiver_url do
    [name | _] = Target.demo_receiver_names()
    Target.demo_receiver_url(name)
  end

  ## Filters

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = params |> Map.take(@filter_keys) |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
    {:noreply, push_patch(socket, to: jobs_path(filters, 1))}
  end

  def handle_event("clear_filters", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/jobs")}

  ## Create

  def handle_event("validate", %{"job" => %{"kind" => "worker"} = params}, socket) do
    {changeset, text} = build_job(params)

    {:noreply,
     assign(socket,
       kind: "worker",
       form: to_form(%{changeset | action: :validate}, as: :job),
       payload_text: text
     )}
  end

  # Typing must stay cheap, so only the offline checks run here. The target
  # check (a DNS lookup) waits for the save.
  def handle_event("validate", %{"job" => params}, socket) do
    params = Map.merge(webhook_defaults(socket, socket.assigns.targets), params)
    rows = WebhookForm.header_rows(params, socket.assigns.header_rows)
    {attrs, local_errors} = webhook_attrs(params, rows)

    request_errors =
      case Request.normalize(attrs) do
        {:ok, _} -> []
        {:error, errs} -> Enum.reject(errs, &(&1 == {:url, "is required"} and params["url"] == ""))
      end

    errors = local_errors ++ Enum.map(request_errors, fn {f, msg} -> {f, {msg, []}} end)

    {:noreply,
     assign(socket, kind: "webhook", header_rows: rows, wh_form: webhook_form(params, errors))}
  end

  def handle_event("save", %{"job" => %{"kind" => "worker"} = params}, socket) do
    {changeset, text} = build_job(params)

    with true <- changeset.valid?,
         {:ok, job} <- DistributedTaskQueue.add_job(params["queue_name"], changeset.params) do
      {:noreply, created(socket, job)}
    else
      false ->
        {:noreply,
         assign(socket,
           form: to_form(%{changeset | action: :insert}, as: :job),
           payload_text: text
         )}

      {:error, failed} ->
        {:noreply, assign(socket, form: to_form(failed, as: :job), payload_text: text)}
    end
  end

  def handle_event("save", %{"job" => params}, socket) do
    params = Map.merge(webhook_defaults(socket, socket.assigns.targets), params)
    rows = WebhookForm.header_rows(params, socket.assigns.header_rows)

    result =
      case webhook_attrs(params, rows) do
        {attrs, []} -> Webhooks.enqueue(attrs)
        {_attrs, local_errors} -> {:local_errors, local_errors}
      end

    case result do
      {:ok, job} ->
        {:noreply, created(socket, job)}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           header_rows: rows,
           wh_form: webhook_form(params, changeset_errors(changeset))
         )}

      {:local_errors, errors} ->
        {:noreply, assign(socket, header_rows: rows, wh_form: webhook_form(params, errors))}
    end
  end

  def handle_event("add_header", _params, socket),
    do: {:noreply, update(socket, :header_rows, &(&1 ++ [%{key: "", value: ""}]))}

  def handle_event("remove_header", %{"index" => index}, socket) do
    rows = List.delete_at(socket.assigns.header_rows, String.to_integer(index))
    {:noreply, assign(socket, header_rows: rows)}
  end

  ## Row actions

  def handle_event("delete", %{"id" => id}, socket) do
    socket =
      case DistributedTaskQueue.delete_job(id) do
        {:ok, job} ->
          Events.broadcast([:dtq, :console, :job_deleted], %{job_id: job.id})
          put_flash(socket, :info, "Job ##{job.id} deleted.")

        {:error, :job_running} ->
          put_flash(socket, :error, "Job ##{id} is running and cannot be deleted.")

        {:error, :not_found} ->
          put_flash(socket, :error, "Job ##{id} no longer exists.")
      end

    {:noreply, LiveRefresh.refresh(socket)}
  end

  defp created(socket, job) do
    Events.broadcast([:dtq, :console, :job_created], %{job_id: job.id})

    socket
    |> put_flash(:info, "Job ##{job.id} enqueued on #{job.queue_name}.")
    |> push_patch(to: jobs_path(socket.assigns.filters, 1))
  end

  ## Webhook form

  # The form is built from the raw params rather than a changeset: a webhook
  # job's fields live inside its payload, so there is no schema to cast into.
  defp webhook_form(params, errors), do: to_form(params, as: :job, errors: errors)

  # Turns form params into what `Webhooks.enqueue/1` takes, the same call the
  # API makes, so both share one rule set. Problems that only exist in the
  # form (a half-typed number or date) come back as errors for the form.
  defp webhook_attrs(params, rows) do
    attrs =
      params
      |> WebhookForm.request_attrs(rows)
      |> Map.merge(%{
        "queue" => blank_to_nil(params["queue_name"]),
        "max_attempts" => parse_int(params["max_attempts"])
      })

    case schedule_attrs(params) do
      {:ok, schedule} -> {Map.merge(attrs, schedule), []}
      {:error, error} -> {attrs, [when: error]}
    end
  end

  defp schedule_attrs(%{"when" => "in"} = params) do
    case Integer.parse(String.trim(params["in_minutes"] || "")) do
      {minutes, ""} when minutes >= 0 -> {:ok, %{"delay_seconds" => minutes * 60}}
      _ -> {:error, {"Enter a whole number of minutes.", []}}
    end
  end

  # The browser sends no offset, so the time is read as UTC.
  defp schedule_attrs(%{"when" => "at"} = params) do
    text = String.trim(params["run_at"] || "")
    text = if String.length(text) == 16, do: text <> ":00", else: text

    case NaiveDateTime.from_iso8601(text) do
      {:ok, naive} ->
        {:ok, %{"run_at" => naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()}}

      _ ->
        {:error, {"Pick a date and time.", []}}
    end
  end

  defp schedule_attrs(_params), do: {:ok, %{}}

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_int(value) when value in [nil, ""], do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  # `Webhooks.enqueue/1` reports request problems under :payload.
  defp changeset_errors(changeset) do
    for {field, error} <- changeset.errors do
      message = CoreComponents.translate_error(error)

      case field do
        :payload -> WebhookForm.payload_error(message)
        :scheduled_at -> {:when, {message, []}}
        _ -> {field, {message, []}}
      end
    end
  end

  # The payload arrives as JSON text; the schema field is a map.
  defp build_job(params) do
    text = params["payload"] || "{}"
    {decoded, json_error} = JsonField.decode(params, "payload")

    changeset =
      %Job{}
      |> Job.changeset(decoded)
      |> validate_queue_exists()
      |> JsonField.put_error(:payload, json_error)

    {changeset, text}
  end

  defp validate_queue_exists(changeset) do
    queue = Ecto.Changeset.get_field(changeset, :queue_name)

    if queue && is_nil(DistributedTaskQueue.get_queue(queue)),
      do: Ecto.Changeset.add_error(changeset, :queue_name, "does not exist"),
      else: changeset
  end

  defp parse_page(nil), do: 1

  defp parse_page(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp jobs_path(filters, page) do
    query = if page > 1, do: Map.put(filters, "page", page), else: filters
    ~p"/jobs?#{query}"
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        last_page: max(div(assigns.total + Dashboard.page_size() - 1, Dashboard.page_size()), 1)
      )

    ~H"""
    <.page_header title="Jobs">
      <:subtitle>
        {@total} {pluralize(@total, "job", "jobs")}{if @filters != %{}, do: " match these filters"}
      </:subtitle>
      <:actions>
        <.btn variant={:primary} patch={jobs_new_path(@filters)} id="new-job">
          <.icon name="hero-plus-mini" class="h-4 w-4" /> New job
        </.btn>
      </:actions>
    </.page_header>

    <form
      id="job-filters"
      phx-change="filter"
      phx-submit="filter"
      class="mb-4 grid grid-cols-2 gap-3 md:grid-cols-[minmax(0,2fr)_repeat(2,minmax(0,1fr))_auto_auto] md:items-end"
    >
      <div class="col-span-2 md:col-span-1">
        <label for="filter-q" class="mb-1 block text-xs font-medium text-zinc-500 dark:text-zinc-400">
          Search
        </label>
        <input
          id="filter-q"
          type="search"
          name="filters[q]"
          value={@filters["q"]}
          placeholder="Job id, worker or error text"
          phx-debounce="300"
          class={filter_input_class()}
        />
      </div>
      <div>
        <label
          for="filter-queue"
          class="mb-1 block text-xs font-medium text-zinc-500 dark:text-zinc-400"
        >
          Queue
        </label>
        <select id="filter-queue" name="filters[queue]" class={filter_input_class()}>
          {Phoenix.HTML.Form.options_for_select(
            [{"All queues", ""} | @queue_names],
            @filters["queue"]
          )}
        </select>
      </div>
      <div>
        <label
          for="filter-status"
          class="mb-1 block text-xs font-medium text-zinc-500 dark:text-zinc-400"
        >
          Status
        </label>
        <select id="filter-status" name="filters[status]" class={filter_input_class()}>
          {Phoenix.HTML.Form.options_for_select(status_options(), @filters["status"])}
        </select>
      </div>
      <label class="flex items-center gap-2 py-2 text-sm text-zinc-700 dark:text-zinc-300">
        <input type="hidden" name="filters[errors]" value="" />
        <input
          type="checkbox"
          name="filters[errors]"
          value="true"
          checked={@filters["errors"] == "true"}
          class="rounded border-zinc-300 text-zinc-900 focus:ring-0 dark:border-zinc-600 dark:bg-zinc-800"
        /> With errors
      </label>
      <.btn :if={@filters != %{}} phx-click="clear_filters" class="self-end">Clear</.btn>
    </form>

    <.empty_state :if={@jobs == [] and @filters == %{}}>
      No jobs yet. Enqueue one with New job, or <code class="font-mono">POST /api/jobs</code>.
    </.empty_state>
    <.empty_state :if={@jobs == [] and @filters != %{}}>
      No jobs match these filters.
    </.empty_state>

    <.surface :if={@jobs != []}>
      <table class="w-full text-left text-sm">
        <thead class={thead_class()}>
          <tr>
            <th class={th_class()}>Job</th>
            <th class={th_class()}>Worker</th>
            <th class={th_class()}>Status</th>
            <th class={th_class()} title="Which server ran it">Node</th>
            <th class={[th_class(), "text-right"]}>Attempts</th>
            <th class={[th_class(), "w-2/5"]}>Last error</th>
            <th class={[th_class(), "text-right"]}>Updated</th>
            <th class={th_class()}><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody class={tbody_class()}>
          <tr :for={job <- @jobs} id={"job-#{job.id}"}>
            <td class={[td_class(), "whitespace-nowrap"]}>
              <.link navigate={~p"/jobs/#{job.id}"} class={[row_link_class(), "font-mono"]}>
                #{job.id}
              </.link>
              <span class="ml-1.5 text-zinc-500 dark:text-zinc-400">{job.queue_name}</span>
            </td>
            <td class={[td_class(), "font-mono text-xs text-zinc-600 dark:text-zinc-300"]}>
              {short_module(job.worker_module)}
            </td>
            <td class={td_class()}><.job_status job={job} /></td>
            <td class={[td_class(), "whitespace-nowrap font-mono text-xs text-zinc-500 dark:text-zinc-400"]}>
              {node_of(job.attempted_by) || "—"}
            </td>
            <td class={num_class()}>{job.attempts}/{job.max_attempts}</td>
            <td class={[td_class(), "max-w-xs"]}>
              <.error_text message={job.error_message} />
              <span :if={!job.error_message} class="text-zinc-400 dark:text-zinc-600">None</span>
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right text-zinc-500 dark:text-zinc-400"]}>
              <.rel_time at={job.updated_at} now={@now} />
            </td>
            <td class={[td_class(), "text-right"]}>
              <.btn
                :if={job.status != "started"}
                size={:sm}
                variant={:danger}
                phx-click="delete"
                phx-value-id={job.id}
                data-confirm={"Delete job ##{job.id}?"}
              >
                Delete
              </.btn>
            </td>
          </tr>
        </tbody>
      </table>
    </.surface>

    <nav
      :if={@last_page > 1}
      aria-label="Pagination"
      class="mt-4 flex items-center justify-between text-sm text-zinc-500 dark:text-zinc-400"
    >
      <span>Page {@page} of {@last_page}</span>
      <div class="flex gap-2">
        <.btn :if={@page > 1} size={:sm} patch={jobs_path(@filters, @page - 1)}>Previous</.btn>
        <.btn :if={@page < @last_page} size={:sm} patch={jobs_path(@filters, @page + 1)}>
          Next
        </.btn>
      </div>
    </nav>

    <.modal
      :if={@live_action == :new}
      id="job-modal"
      show
      on_cancel={JS.patch(jobs_path(@filters, @page))}
    >
      <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">New job</h2>
      <.simple_form
        :if={@kind == "webhook"}
        for={@wh_form}
        id="job-form"
        phx-change="validate"
        phx-submit="save"
      >
        <.kind_picker kind={@kind} />
        <WebhookFields.fields form={@wh_form} targets={@targets} header_rows={@header_rows} />
        <.input
          field={@wh_form[:queue_name]}
          type="select"
          label="Queue"
          prompt="Choose a queue"
          options={@queue_names}
        />
        <div>
          <.input
            field={@wh_form[:when]}
            type="select"
            label="When"
            options={[
              {"Now", "now"},
              {"In a number of minutes", "in"},
              {"At a date and time (UTC)", "at"}
            ]}
          />
          <.input
            :if={@wh_form[:when].value == "in"}
            field={@wh_form[:in_minutes]}
            type="number"
            min="0"
            label="In … minutes"
          />
          <.input
            :if={@wh_form[:when].value == "at"}
            field={@wh_form[:run_at]}
            type="datetime-local"
            label="Date and time (UTC)"
          />
          <.error :for={msg <- WebhookFields.field_errors(@wh_form, :when)}>{msg}</.error>
        </div>
        <.input field={@wh_form[:max_attempts]} type="number" min="1" label="Max attempts" />
        <:actions>
          <.btn patch={jobs_path(@filters, @page)}>Cancel</.btn>
          <.btn variant={:primary} type="submit" phx-disable-with="Enqueuing">Enqueue</.btn>
        </:actions>
      </.simple_form>
      <.simple_form
        :if={@kind == "worker"}
        for={@form}
        id="job-form"
        phx-change="validate"
        phx-submit="save"
      >
        <.kind_picker kind={@kind} />
        <.input
          field={@form[:queue_name]}
          type="select"
          label="Queue"
          prompt="Choose a queue"
          options={@queue_names}
        />
        <.input
          field={@form[:worker_module]}
          label="Worker module"
          list="known-workers"
          placeholder="DistributedTaskQueue.EmailWorker"
          autocomplete="off"
          phx-debounce="300"
        />
        <datalist id="known-workers">
          <option :for={w <- @workers} value={w} />
        </datalist>
        <.input
          id="job_payload"
          name="job[payload]"
          type="textarea"
          label="Payload (JSON object)"
          value={@payload_text}
          errors={JsonField.errors(@form, :payload)}
          rows="6"
          phx-debounce="400"
        />
        <.input field={@form[:max_attempts]} type="number" min="1" label="Max attempts" />
        <:actions>
          <.btn patch={jobs_path(@filters, @page)}>Cancel</.btn>
          <.btn variant={:primary} type="submit" phx-disable-with="Enqueuing">Enqueue</.btn>
        </:actions>
      </.simple_form>
    </.modal>
    """
  end

  attr :kind, :string, required: true

  defp kind_picker(assigns) do
    ~H"""
    <.input
      id="job_kind"
      name="job[kind]"
      type="select"
      label="What should this job do?"
      value={@kind}
      options={[{"Call a URL", "webhook"}, {"Run an Elixir worker", "worker"}]}
    />
    """
  end

  defp jobs_new_path(filters), do: ~p"/jobs/new?#{filters}"

  defp status_options do
    [{"Any status", ""}] ++
      Enum.map(Dashboard.statuses(), &{status_name(&1), &1}) ++ [{"Dead letter", "dead"}]
  end

  defp filter_input_class,
    do:
      "block w-full rounded-lg border-zinc-300 bg-white text-sm text-zinc-900 focus:border-zinc-400 " <>
        "focus:ring-0 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
end
