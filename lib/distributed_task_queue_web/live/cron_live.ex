defmodule DistributedTaskQueueWeb.CronLive do
  @moduledoc "Cron jobs with create, edit, enable/disable and delete."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{CronJob, Dashboard, Events, Webhooks}
  alias DistributedTaskQueue.Webhooks.{Request, Target}
  alias DistributedTaskQueue.Workers.Webhook, as: WebhookWorker

  alias DistributedTaskQueueWeb.{
    JsonField,
    LiveRefresh,
    ScheduleText,
    WebhookFields,
    WebhookForm
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Cron",
       nav: :cron,
       workers: Dashboard.known_workers(),
       timezones: Tzdata.zone_list(),
       config_names: Dashboard.config_cron_names(),
       targets: Webhooks.targets()
     )
     |> refresh()}
  end

  def refresh(socket) do
    assign(socket,
      crons: Dashboard.cron_jobs(),
      missing: Map.new(Dashboard.crons_missing_queue()),
      queue_names: Dashboard.queue_names()
    )
  end

  @impl true
  def handle_params(params, _url, socket), do: {:noreply, apply_action(socket, params)}

  defp apply_action(%{assigns: %{live_action: :new}} = socket, _params) do
    queue = if "webhooks" in Dashboard.queue_names(), do: "webhooks"

    cron = %CronJob{
      payload: %{},
      max_attempts: 3,
      overlap: false,
      enabled: true,
      queue_name: queue
    }

    open_form(socket, cron, "cron")
  end

  defp apply_action(%{assigns: %{live_action: :edit}} = socket, %{"id" => id}) do
    case DistributedTaskQueue.get_cron_job(id) do
      nil ->
        socket
        |> put_flash(:error, "That cron job no longer exists.")
        |> push_patch(to: ~p"/cron")

      cron ->
        open_form(socket, cron, if(cron.interval_seconds, do: "interval", else: "cron"))
    end
  end

  defp apply_action(socket, _params), do: assign(socket, editing: nil, form: nil)

  defp open_form(socket, cron, schedule_type) do
    {kind, wh_params, rows} = webhook_state(socket, cron)

    assign(socket,
      editing: cron,
      schedule_type: schedule_type,
      payload_text: JsonField.encode(cron.payload),
      form: to_form(CronJob.changeset(cron, %{}), as: :cron),
      kind: kind,
      header_rows: rows,
      wh_form: webhook_form(wh_params, [])
    )
  end

  # A new cron starts as a webhook; an existing one is a webhook when it runs
  # the webhook worker. Credential headers are shown masked: the form never
  # needs the real value, and `build_webhook/5` puts the stored one back on save.
  defp webhook_state(socket, %CronJob{worker_module: module, payload: payload} = cron) do
    cond do
      cron.id && module == WebhookWorker.module_name() ->
        params = %{
          "url" => payload["url"] || "",
          "method" => payload["method"] || "POST",
          "body" => payload["body"] || ""
        }

        {"webhook", params, WebhookForm.rows_for(payload["headers"] || %{})}

      cron.id ->
        {"worker", webhook_defaults(socket), []}

      true ->
        {"webhook", webhook_defaults(socket), []}
    end
  end

  defp webhook_defaults(socket) do
    url =
      if socket.assigns.targets == :demo_receivers do
        [name | _] = Target.demo_receiver_names()
        Target.demo_receiver_url(name)
      else
        ""
      end

    %{"url" => url, "method" => "POST", "body" => ""}
  end

  # The webhook map nests under the cron's params, so its inputs are named
  # cron[webhook][...].
  defp webhook_form(params, errors),
    do: to_form(params, as: "cron[webhook]", id: "cron_webhook", errors: errors)

  @impl true
  def handle_event("validate", %{"cron" => %{"kind" => "webhook"} = params}, socket) do
    wh = Map.merge(webhook_defaults(socket), params["webhook"] || %{})
    rows = WebhookForm.header_rows(wh, socket.assigns.header_rows)
    {changeset, wh_errors, type} = build_webhook(socket, params, wh, rows, :validate)

    {:noreply,
     assign(socket,
       kind: "webhook",
       form: to_form(%{changeset | action: :validate}, as: :cron),
       wh_form: webhook_form(wh, wh_errors),
       header_rows: rows,
       schedule_type: type
     )}
  end

  def handle_event("validate", %{"cron" => params}, socket) do
    {changeset, text, type} = build(socket.assigns.editing, params)

    {:noreply,
     assign(socket,
       kind: "worker",
       form: to_form(%{changeset | action: :validate}, as: :cron),
       payload_text: text,
       schedule_type: type
     )}
  end

  def handle_event("save", %{"cron" => %{"kind" => "webhook"} = params}, socket) do
    wh = Map.merge(webhook_defaults(socket), params["webhook"] || %{})
    rows = WebhookForm.header_rows(wh, socket.assigns.header_rows)
    {changeset, wh_errors, type} = build_webhook(socket, params, wh, rows, :save)

    if changeset.valid? and wh_errors == [] do
      save(socket, changeset.params)
    else
      {:noreply,
       assign(socket,
         kind: "webhook",
         form: to_form(%{changeset | action: :insert}, as: :cron),
         wh_form: webhook_form(wh, wh_errors),
         header_rows: rows,
         schedule_type: type
       )}
    end
  end

  def handle_event("save", %{"cron" => params}, socket) do
    {changeset, text, type} = build(socket.assigns.editing, params)

    if changeset.valid? do
      save(socket, changeset.params)
    else
      {:noreply,
       assign(socket,
         kind: "worker",
         form: to_form(%{changeset | action: :insert}, as: :cron),
         payload_text: text,
         schedule_type: type
       )}
    end
  end

  def handle_event("add_header", _params, socket),
    do: {:noreply, update(socket, :header_rows, &(&1 ++ [%{key: "", value: ""}]))}

  def handle_event("remove_header", %{"index" => index}, socket) do
    rows = List.delete_at(socket.assigns.header_rows, String.to_integer(index))
    {:noreply, assign(socket, header_rows: rows)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    socket =
      with %CronJob{} = cron <- DistributedTaskQueue.get_cron_job(id),
           fun =
             if(cron.enabled,
               do: &DistributedTaskQueue.disable_cron_job/1,
               else: &DistributedTaskQueue.enable_cron_job/1
             ),
           {:ok, updated} <- fun.(cron) do
        Events.broadcast([:dtq, :console, :cron_changed], %{cron_job_id: updated.id})

        put_flash(
          socket,
          :info,
          "Cron job #{updated.name} #{if updated.enabled, do: "enabled", else: "disabled"}."
        )
      else
        nil -> put_flash(socket, :error, "That cron job no longer exists.")
        {:error, _} -> put_flash(socket, :error, "The cron job could not be updated.")
      end

    {:noreply, LiveRefresh.refresh(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket =
      with %CronJob{} = cron <- DistributedTaskQueue.get_cron_job(id),
           {:ok, deleted} <- DistributedTaskQueue.delete_cron_job(cron) do
        Events.broadcast([:dtq, :console, :cron_changed], %{cron_job_id: deleted.id})
        put_flash(socket, :info, "Cron job #{deleted.name} deleted.")
      else
        nil -> put_flash(socket, :error, "That cron job no longer exists.")
        {:error, _} -> put_flash(socket, :error, "The cron job could not be deleted.")
      end

    {:noreply, LiveRefresh.refresh(socket)}
  end

  defp save(socket, attrs) do
    result =
      if socket.assigns.live_action == :new,
        do: DistributedTaskQueue.create_cron_job(attrs),
        else: DistributedTaskQueue.update_cron_job(socket.assigns.editing, attrs)

    case result do
      {:ok, cron} ->
        Events.broadcast([:dtq, :console, :cron_changed], %{cron_job_id: cron.id})

        {:noreply,
         socket
         |> put_flash(:info, "Cron job #{cron.name} saved.")
         |> push_patch(to: ~p"/cron")
         |> LiveRefresh.refresh()}

      {:error, failed} ->
        {:noreply, assign(socket, form: to_form(failed, as: :cron))}
    end
  end

  # Typing must stay cheap, so validating only runs the offline request checks.
  # Saving goes through `Webhooks.cron_attrs/1`, the call the API makes, which
  # also checks the target (a DNS lookup). Returns the cron changeset and the
  # request's errors for the webhook fields.
  defp build_webhook(socket, params, wh, rows, mode) do
    type = schedule_type(params)
    stored = stored_request(socket.assigns)

    request =
      wh
      |> WebhookForm.request_attrs(rows)
      |> Map.update!("headers", &Request.merge_masked(&1, stored["headers"] || %{}))
      |> Map.put("timeout_ms", stored["timeout_ms"])

    {payload, wh_errors} = request_payload(request, mode)

    cron_params =
      params
      |> Map.drop(["kind", "webhook", "payload"])
      |> Map.merge(%{"worker_module" => WebhookWorker.module_name(), "payload" => payload})
      |> normalize_schedule(type)

    {CronJob.changeset(socket.assigns.editing, cron_params), wh_errors, type}
  end

  defp request_payload(request, :validate) do
    case Request.normalize(request) do
      {:ok, payload} ->
        {payload, []}

      {:error, errors} ->
        errors = Enum.reject(errors, &(&1 == {:url, "is required"} and request["url"] == ""))
        {%{}, Enum.map(errors, fn {field, msg} -> {field, {msg, []}} end)}
    end
  end

  defp request_payload(request, :save) do
    {messages, attrs} =
      %{"webhook" => request} |> Webhooks.cron_attrs() |> Map.pop("webhook_errors")

    case messages do
      nil -> {attrs["payload"], []}
      messages -> {%{}, Enum.map(messages, &WebhookForm.payload_error/1)}
    end
  end

  # What the cron being edited already sends, so unchanged masked headers keep
  # their secret and settings the form does not show (the timeout) survive.
  defp stored_request(%{editing: %CronJob{id: id, worker_module: module, payload: payload}})
       when not is_nil(id) do
    if module == WebhookWorker.module_name(), do: payload || %{}, else: %{}
  end

  defp stored_request(_assigns), do: %{}

  defp schedule_type(params),
    do: if(params["schedule_type"] == "interval", do: "interval", else: "cron")

  # Only one schedule kind is kept; the other field is cleared so the XOR
  # validation sees exactly one. Timezones only mean something for cron
  # expressions.
  defp normalize_schedule(params, type) do
    case type do
      "cron" -> Map.put(params, "interval_seconds", nil)
      "interval" -> Map.merge(params, %{"cron_expression" => nil, "timezone" => nil})
    end
    |> Map.update("timezone", nil, &blank_to_nil/1)
    |> Map.update("description", nil, &blank_to_nil/1)
  end

  defp build(cron, params) do
    type = schedule_type(params)
    text = params["payload"] || "{}"
    params = normalize_schedule(params, type)

    {decoded, json_error} = JsonField.decode(params, "payload")

    changeset =
      cron
      |> CronJob.changeset(decoded)
      |> JsonField.put_error(:payload, json_error)

    {changeset, text, type}
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Cron">
      <:subtitle>Recurring jobs. Each tick is claimed by exactly one node.</:subtitle>
      <:actions>
        <.btn variant={:primary} patch={~p"/cron/new"} id="new-cron">
          <.icon name="hero-plus-mini" class="h-4 w-4" /> New cron job
        </.btn>
      </:actions>
    </.page_header>

    <div :if={@missing != %{}} class="mb-6 space-y-3">
      <.callout
        :for={{cron, queue} <- @missing}
        kind={:error}
        title={"#{cron} targets queue #{queue}, which does not exist"}
      >
        It will not run until the queue is created.
        <.link navigate={~p"/queues/new?name=#{queue}"} class="font-medium underline">
          Create queue {queue}
        </.link>
      </.callout>
    </div>

    <.empty_state :if={@crons == []}>
      No cron jobs yet. Create one here, or declare them under
      <code class="font-mono">:cron_jobs</code>
      in config.
    </.empty_state>

    <.surface :if={@crons != []}>
      <table class="w-full text-left text-sm">
        <thead class={thead_class()}>
          <tr>
            <th class={th_class()}>Name</th>
            <th class={th_class()}>Schedule</th>
            <th class={th_class()}>Queue</th>
            <th class={[th_class(), "text-right"]}>Next run</th>
            <th class={[th_class(), "text-right"]}>Last run</th>
            <th class={th_class()}><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody class={tbody_class()}>
          <tr :for={cron <- @crons} id={"cron-#{cron.id}"} class={!cron.enabled && "opacity-60"}>
            <td class={td_class()}>
              <div class="flex items-center gap-2">
                <span class="font-medium text-zinc-900 dark:text-zinc-100">{cron.name}</span>
                <span
                  :if={MapSet.member?(@config_names, cron.name)}
                  class={[badge_class(), tone(:zinc)]}
                  title="Declared in config. Config values are re-applied at every boot."
                >
                  config
                </span>
              </div>
              <p class="font-mono text-xs text-zinc-500 dark:text-zinc-400">
                {short_module(cron.worker_module)}
              </p>
            </td>
            <td class={td_class()}>
              <span class="text-zinc-700 dark:text-zinc-300" title={schedule(cron)}>
                {ScheduleText.describe(cron)}
              </span>
            </td>
            <td class={td_class()}>
              <span class={Map.has_key?(@missing, cron.name) && "text-rose-700 dark:text-rose-300"}>
                {cron.queue_name}
              </span>
              <p
                :if={Map.has_key?(@missing, cron.name)}
                class="text-xs text-rose-700 dark:text-rose-300"
              >
                Queue missing
              </p>
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right"]}>
              <span :if={!cron.enabled} class="text-zinc-500 dark:text-zinc-400">Disabled</span>
              <.rel_time
                :if={cron.enabled}
                at={cron.next_run_at}
                now={@now}
                empty="Not scheduled"
                class="text-zinc-900 dark:text-zinc-100"
              />
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right text-zinc-500 dark:text-zinc-400"]}>
              <.rel_time at={cron.last_run_at} now={@now} />
            </td>
            <td class={[td_class(), "whitespace-nowrap text-right"]}>
              <div class="flex justify-end gap-1.5">
                <.btn size={:sm} phx-click="toggle" phx-value-id={cron.id}>
                  {if cron.enabled, do: "Disable", else: "Enable"}
                </.btn>
                <.btn size={:sm} patch={~p"/cron/#{cron.id}/edit"} id={"edit-cron-#{cron.id}"}>
                  Edit
                </.btn>
                <.btn
                  size={:sm}
                  variant={:danger}
                  phx-click="delete"
                  phx-value-id={cron.id}
                  data-confirm={delete_confirm(cron, @config_names)}
                >
                  Delete
                </.btn>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </.surface>

    <.modal :if={@live_action in [:new, :edit]} id="cron-modal" show on_cancel={JS.patch(~p"/cron")}>
      <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">
        {if @live_action == :new, do: "New cron job", else: "Edit #{@editing.name}"}
      </h2>
      <p
        :if={@live_action == :edit && MapSet.member?(@config_names, @editing.name)}
        class="mt-2 text-sm text-amber-700 dark:text-amber-300"
      >
        This cron job is declared in config. Changes here last until the next boot, when config
        is re-applied.
      </p>
      <.simple_form for={@form} id="cron-form" phx-change="validate" phx-submit="save">
        <.input
          id="cron_kind"
          name="cron[kind]"
          type="select"
          label="What should this cron job do?"
          value={@kind}
          options={[{"Call a URL", "webhook"}, {"Run an Elixir worker", "worker"}]}
        />
        <div class="grid gap-6 sm:grid-cols-2">
          <.input field={@form[:name]} label="Name" autocomplete="off" phx-debounce="300" />
          <.input
            field={@form[:queue_name]}
            type="select"
            label="Queue"
            prompt="Choose a queue"
            options={@queue_names}
          />
        </div>
        <WebhookFields.fields
          :if={@kind == "webhook"}
          form={@wh_form}
          targets={@targets}
          header_rows={@header_rows}
        />
        <.input
          :if={@kind == "worker"}
          field={@form[:worker_module]}
          label="Worker module"
          list="cron-workers"
          placeholder="DistributedTaskQueue.EmailWorker"
          autocomplete="off"
          phx-debounce="300"
        />
        <datalist :if={@kind == "worker"} id="cron-workers">
          <option :for={w <- @workers} value={w} />
        </datalist>

        <fieldset>
          <legend class="text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200">
            Schedule
          </legend>
          <div class="mt-2 flex gap-6 text-sm text-zinc-700 dark:text-zinc-300">
            <label class="flex items-center gap-2">
              <input
                type="radio"
                name="cron[schedule_type]"
                value="cron"
                checked={@schedule_type == "cron"}
                class="border-zinc-300 text-zinc-900 focus:ring-0 dark:border-zinc-600 dark:bg-zinc-800"
              /> Cron expression
            </label>
            <label class="flex items-center gap-2">
              <input
                type="radio"
                name="cron[schedule_type]"
                value="interval"
                checked={@schedule_type == "interval"}
                class="border-zinc-300 text-zinc-900 focus:ring-0 dark:border-zinc-600 dark:bg-zinc-800"
              /> Fixed interval
            </label>
          </div>
        </fieldset>

        <div :if={@schedule_type == "cron"} class="grid gap-6 sm:grid-cols-2">
          <.input
            field={@form[:cron_expression]}
            label="Cron expression"
            placeholder="*/5 * * * *"
            phx-debounce="300"
          />
          <.input
            field={@form[:timezone]}
            label="Timezone (blank for UTC)"
            list="timezones"
            placeholder="Africa/Nairobi"
            autocomplete="off"
            phx-debounce="300"
          />
          <datalist id="timezones">
            <option :for={tz <- @timezones} value={tz} />
          </datalist>
        </div>
        <.input
          :if={@schedule_type == "interval"}
          field={@form[:interval_seconds]}
          type="number"
          min="1"
          label="Every N seconds"
          phx-debounce="300"
        />

        <.input
          :if={@kind == "worker"}
          id="cron_payload"
          name="cron[payload]"
          type="textarea"
          label="Payload (JSON object)"
          value={@payload_text}
          errors={JsonField.errors(@form, :payload)}
          rows="5"
          phx-debounce="400"
        />
        <div class="grid gap-6 sm:grid-cols-2">
          <.input field={@form[:max_attempts]} type="number" min="1" label="Max attempts" />
          <.input field={@form[:description]} label="Description" phx-debounce="300" />
        </div>
        <.input
          field={@form[:overlap]}
          type="checkbox"
          label="Allow overlapping runs (start a new run while the previous one is still active)"
        />
        <:actions>
          <.btn patch={~p"/cron"}>Cancel</.btn>
          <.btn variant={:primary} type="submit" phx-disable-with="Saving">Save</.btn>
        </:actions>
      </.simple_form>
    </.modal>
    """
  end

  defp delete_confirm(cron, config_names) do
    if MapSet.member?(config_names, cron.name),
      do:
        "Delete #{cron.name}? It is declared in config, so it will be recreated at the next boot.",
      else: "Delete cron job #{cron.name}?"
  end
end
