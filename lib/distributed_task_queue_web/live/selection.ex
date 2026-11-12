defmodule DistributedTaskQueueWeb.Selection do
  @moduledoc """
  Row selection and the bulk-action bar, shared by every console list.

  A page calls `track/2` from its `refresh/1` with the ids of the rows it shows,
  delegates the `"select…"` events to `handle_event/3`, and renders
  `page_checkbox/1`, `checkbox/1` and `bulk_bar/1`. Only rows currently on
  screen can be selected, and a row that leaves the screen (deleted, filtered
  out) is dropped from the selection, so a bulk action never touches something
  the user cannot see.

  Ids keep their own type (integer job ids, string queue names); the strings
  that come back from the browser are matched against the rows on screen.
  """

  use Phoenix.Component

  import DistributedTaskQueueWeb.ConsoleComponents, only: [btn: 1, pluralize: 3]

  @doc "Record the rows on screen, in display order, and drop any selected row that is gone."
  def track(socket, ids) do
    selected = Map.get(socket.assigns, :selected, MapSet.new())
    assign(socket, selectable: ids, selected: MapSet.intersection(selected, MapSet.new(ids)))
  end

  def clear(socket), do: assign(socket, selected: MapSet.new())

  @doc "The selected ids, in the order the rows are shown."
  def selected_ids(%{assigns: %{selectable: ids, selected: selected}}),
    do: Enum.filter(ids, &MapSet.member?(selected, &1))

  def handle_event("select", %{"id" => raw}, socket) do
    case Enum.find(socket.assigns.selectable, &(to_string(&1) == raw)) do
      nil ->
        socket

      id ->
        selected = socket.assigns.selected

        selected =
          if MapSet.member?(selected, id),
            do: MapSet.delete(selected, id),
            else: MapSet.put(selected, id)

        assign(socket, selected: selected)
    end
  end

  def handle_event("select_page", _params, socket) do
    all = MapSet.new(socket.assigns.selectable)

    if MapSet.subset?(all, socket.assigns.selected),
      do: clear(socket),
      else: assign(socket, selected: all)
  end

  def handle_event("select_clear", _params, socket), do: clear(socket)

  @doc """
  One line for a bulk action's outcome, e.g. "Paused 3 queues. Skipped 1: gone."

  `result` is `%{succeeded: [...], failed: [{id, reason}]}`; `reason_text`
  turns a failure reason into a short phrase.
  """
  def summary(verb, {one, many}, %{succeeded: succeeded, failed: failed}, reason_text) do
    n = length(succeeded)
    done = "#{verb} #{n} #{pluralize(n, one, many)}."

    case failed do
      [] -> done
      _ -> "#{done} Skipped #{length(failed)}: #{reasons(failed, reason_text)}."
    end
  end

  defp reasons(failed, reason_text) do
    failed
    |> Enum.frequencies_by(fn {_id, reason} -> reason_text.(reason) end)
    |> Enum.sort_by(fn {_text, n} -> -n end)
    |> case do
      # One reason covers them all, so the count before the colon is enough.
      [{text, _n}] -> text
      many -> Enum.map_join(many, ", ", fn {text, n} -> "#{n} #{text}" end)
    end
  end

  @doc """
  Apply `fun` to each id, collecting `{:ok, _}` and `{:error, reason}` results
  the way `summary/4` reads them.
  """
  def run(ids, fun) do
    {succeeded, failed} =
      Enum.reduce(ids, {[], []}, fn id, {ok, errors} ->
        case fun.(id) do
          {:ok, _} -> {[id | ok], errors}
          {:error, reason} -> {ok, [{id, reason} | errors]}
        end
      end)

    %{succeeded: Enum.reverse(succeeded), failed: Enum.reverse(failed)}
  end

  ## Components

  attr :selectable, :list, required: true
  attr :selected, :any, required: true
  attr :label, :string, default: "Select every row"

  def page_checkbox(assigns) do
    ~H"""
    <input
      type="checkbox"
      id="select-page"
      aria-label={@label}
      phx-click="select_page"
      checked={@selectable != [] and Enum.all?(@selectable, &MapSet.member?(@selected, &1))}
      class="rounded border-zinc-300 dark:border-zinc-700"
    />
    """
  end

  attr :id, :any, required: true
  attr :selected, :any, required: true
  attr :label, :string, required: true

  def checkbox(assigns) do
    ~H"""
    <input
      type="checkbox"
      id={"select-#{@id}"}
      aria-label={@label}
      phx-click="select"
      phx-value-id={@id}
      checked={MapSet.member?(@selected, @id)}
      class="rounded border-zinc-300 dark:border-zinc-700"
    />
    """
  end

  attr :selected, :any, required: true
  slot :inner_block, required: true

  def bulk_bar(assigns) do
    ~H"""
    <div
      :if={MapSet.size(@selected) > 0}
      id="bulk-bar"
      class="mb-3 flex flex-wrap items-center gap-2 rounded-lg border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm dark:border-zinc-800 dark:bg-zinc-900"
    >
      <span class="mr-1 font-medium">{MapSet.size(@selected)} selected</span>
      {render_slot(@inner_block)}
      <.btn size={:sm} phx-click="select_clear" class="ml-auto">Clear selection</.btn>
    </div>
    """
  end
end
