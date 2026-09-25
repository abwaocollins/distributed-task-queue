defmodule DistributedTaskQueueWeb.JsonField do
  @moduledoc """
  Edits a `:map` schema field as JSON text in a form.

  The textarea posts a string; the changeset wants a map. `decode/2` swaps the
  text for the decoded object before the changeset runs, and `put_error/3`
  replaces Ecto's generic "can't be blank" with the actual parse problem.
  """

  import Ecto.Changeset, only: [add_error: 3]

  @doc """
  Returns `{params, error}` where `params` has `key` decoded to a map when the
  text is a JSON object, and `error` is `nil` or a message for the form.
  """
  def decode(params, key) do
    case Map.fetch(params, key) do
      {:ok, text} when is_binary(text) -> decode_text(params, key, String.trim(text))
      _ -> {params, nil}
    end
  end

  defp decode_text(params, key, ""), do: {Map.put(params, key, %{}), nil}

  defp decode_text(params, key, text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) ->
        {Map.put(params, key, map), nil}

      {:ok, _other} ->
        {Map.delete(params, key), "must be a JSON object, like {\"id\": 1}"}

      {:error, %Jason.DecodeError{} = e} ->
        {Map.delete(params, key), "is not valid JSON: #{Exception.message(e)}"}
    end
  end

  def put_error(changeset, _field, nil), do: changeset

  def put_error(changeset, field, message) do
    %{changeset | errors: Keyword.delete(changeset.errors, field)}
    |> add_error(field, message)
  end

  @doc """
  Translated errors for `field`, once the form has been validated. The JSON
  textarea is rendered outside `@form[field]` (its value is text, not the
  map), so it cannot rely on `used_input?`.
  """
  def errors(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: nil}}, _field), do: []

  def errors(%Phoenix.HTML.Form{source: changeset}, field) do
    for {^field, error} <- changeset.errors,
        do: DistributedTaskQueueWeb.CoreComponents.translate_error(error)
  end

  @doc "The text to show in the textarea for a stored map."
  def encode(nil), do: "{}"
  def encode(map), do: Jason.encode!(map, pretty: true)
end
