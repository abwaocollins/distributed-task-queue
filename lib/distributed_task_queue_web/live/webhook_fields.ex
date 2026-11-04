defmodule DistributedTaskQueueWeb.WebhookFields do
  @moduledoc """
  The "call a URL" part of a form: where to send, how, with which headers and
  body. Shared by every form that creates a webhook, so they all look and
  read the same.

  The caller owns the form and the header rows (so rows added or removed
  survive re-renders) and handles the `add_header` and `remove_header` clicks.
  """
  use DistributedTaskQueueWeb, :html

  import DistributedTaskQueueWeb.ConsoleComponents, only: [btn: 1]

  alias DistributedTaskQueue.Webhooks.Target

  @methods ~w(GET POST PUT PATCH DELETE)

  attr :form, Phoenix.HTML.Form, required: true
  attr :targets, :atom, values: [:any, :demo_receivers], default: :any
  attr :header_rows, :list, default: []

  def fields(assigns) do
    ~H"""
    <div class="space-y-6">
      <.input
        :if={@targets == :demo_receivers}
        field={@form[:url]}
        type="select"
        label="Send to"
        options={receiver_options()}
      />
      <.input
        :if={@targets != :demo_receivers}
        field={@form[:url]}
        type="text"
        label="URL to call"
        placeholder="https://example.com/hooks/orders"
        autocomplete="off"
        phx-debounce="300"
      />
      <.input field={@form[:method]} type="select" label="Method" options={methods()} />

      <div>
        <.label for={"#{@form.id}_headers_add"}>Headers</.label>
        <p class="text-xs text-zinc-500 dark:text-zinc-400">
          Optional extra details sent with the request, such as an API key.
        </p>
        <div
          :for={{row, i} <- Enum.with_index(@header_rows)}
          id={"header-row-#{i}"}
          class="mt-2 flex items-start gap-2"
        >
          <div class="flex-1">
            <.input
              id={"#{@form.id}_headers_#{i}_key"}
              name={"#{@form.name}[headers][#{i}][key]"}
              value={row.key}
              placeholder="Name, e.g. X-Api-Key"
              aria-label="Header name"
              autocomplete="off"
            />
          </div>
          <div class="flex-1">
            <.input
              id={"#{@form.id}_headers_#{i}_value"}
              name={"#{@form.name}[headers][#{i}][value]"}
              value={row.value}
              placeholder="Value"
              aria-label="Header value"
              autocomplete="off"
            />
          </div>
          <.btn size={:sm} phx-click="remove_header" phx-value-index={i} class="mt-2">
            Remove
          </.btn>
        </div>
        <.error :for={msg <- field_errors(@form, :headers)}>{msg}</.error>
        <.btn size={:sm} id={"#{@form.id}_headers_add"} phx-click="add_header" class="mt-2">
          Add a header
        </.btn>
      </div>

      <.input
        field={@form[:body]}
        type="textarea"
        label="Body (JSON or plain text)"
        placeholder={~s({"order_id": 42})}
        rows="5"
        phx-debounce="400"
      />
    </div>
    """
  end

  @doc "Messages recorded against `field`, as plain strings."
  def field_errors(%Phoenix.HTML.Form{errors: errors}, field) do
    for {^field, {msg, _opts}} <- errors, do: msg
  end

  defp receiver_options do
    for name <- Target.demo_receiver_names(),
        do: {String.capitalize(name), Target.demo_receiver_url(name)}
  end

  defp methods, do: @methods
end
