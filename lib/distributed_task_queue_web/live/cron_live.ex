defmodule DistributedTaskQueueWeb.CronLive do
  @moduledoc "Cron jobs with create, edit, enable/disable and delete."
  use DistributedTaskQueueWeb, :live_view

  alias DistributedTaskQueue.{CronJob, Dashboard, Events}
  alias DistributedTaskQueueWeb.{JsonField, LiveRefresh}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Cron",
       nav: :cron,
       workers: Dashboard.known_workers(),
       timezones: Tzdata.zone_list(),
       config_names: Dashboard.config_cron_names()
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
    cron = %CronJob{payload: %{}, max_attempts: 3, overlap: false, enabled: true}
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
    assign(socket,
      editing: cron,
      schedule_type: schedule_type,
      payload_text: JsonField.encode(cron.payload),
      form: to_form(CronJob.changeset(cron, %{}), as: :cron)
    )
  end

  @impl true
  def handle_event("validate", %{"cron" => params}, socket) do
    {changeset, text, type} = build(socket.assigns.editing, params)

    {:noreply,
     assign(socket,
       form: to_form(%{changeset | action: :validate}, as: :cron),
       payload_text: text,
       schedule_type: type
     )}
  end

  def handle_event("save", %{"cron" => params}, socket) do
    {changeset, text, type} = build(socket.assigns.editing, params)
    attrs = changeset.params

    result =
      cond do
        not changeset.valid? -> {:error, %{changeset | action: :insert}}
        socket.assigns.live_action == :new -> DistributedTaskQueue.create_cron_job(attrs)
        true -> DistributedTaskQueue.update_cron_job(socket.assigns.editing, attrs)
      end

    case result do
      {:ok, cron} ->
        Events.broadcast([:dtq, :console, :cron_changed], %{cron_job_id: cron.id})

        {:noreply,
         socket
         |> put_flash(:info, "Cron job #{cron.name} saved.")
         |> push_patch(to: ~p"/cron")
         |> LiveRefresh.refresh()}

      {:error, failed} ->
        {:noreply,
         assign(socket,
           form: to_form(failed, as: :cron),
           payload_text: text,
           schedule_type: type
         )}
    end
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

  # Only one schedule kind is kept; the other field is cleared so the XOR
  # validation sees exactly one. Timezones only mean something for cron
  # expressions.
  defp build(cron, params) do
    type = if params["schedule_type"] == "interval", do: "interval", else: "cron"
    text = params["payload"] || "{}"

    params =
      case type do
        "cron" -> Map.put(params, "interval_seconds", nil)
        "interval" -> Map.merge(params, %{"cron_expression" => nil, "timezone" => nil})
      end
      |> Map.update("timezone", nil, &blank_to_nil/1)
      |> Map.update("description", nil, &blank_to_nil/1)

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
              <span class="font-mono text-xs text-zinc-700 dark:text-zinc-300">{schedule(cron)}</span>
              <p :if={cron.timezone} class="text-xs text-zinc-500 dark:text-zinc-400">
                {cron.timezone}
              </p>
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
        <.input
          field={@form[:worker_module]}
          label="Worker module"
          list="cron-workers"
          placeholder="DistributedTaskQueue.EmailWorker"
          autocomplete="off"
          phx-debounce="300"
        />
        <datalist id="cron-workers">
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
