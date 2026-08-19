defmodule DistributedTaskQueueWeb.ChangesetErrors do
  @moduledoc """
  Renders `Ecto.Changeset` errors as a single human-readable string for the
  JSON error responses returned by the API controllers.
  """

  @doc """
  Formats every error on `changeset`, interpolating validation options into
  each message.

      iex> format(changeset)
      "queue_name can't be blank; max_attempts must be greater than 0"
  """
  def format(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
