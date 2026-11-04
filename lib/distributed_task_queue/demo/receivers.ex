defmodule DistributedTaskQueue.Demo.Receivers do
  @moduledoc """
  The demo receivers and their Online/Offline switches.

  Switching a receiver offline lasts five minutes, so a visitor who walks away
  never leaves the demo broken. There is no timer: an expired row is treated as
  online and flipped back the next time anyone looks at it.
  """

  import Ecto.Query

  alias DistributedTaskQueue.Demo.Receiver
  alias DistributedTaskQueue.{Events, Repo}
  alias DistributedTaskQueue.Webhooks.Target

  @offline_seconds 300

  @failure_rates %{"payments" => 0.05, "email" => 0.1, "warehouse" => 0.15}

  @doc "Inserts a row for every demo receiver that is missing one. Never overwrites."
  @spec ensure_all() :: :ok
  def ensure_all do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for name <- Target.demo_receiver_names() do
        %{
          name: name,
          online: true,
          failure_rate: Map.get(@failure_rates, name, 0.1),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Receiver, rows, on_conflict: :nothing, conflict_target: :name)
    :ok
  end

  @spec list() :: [Receiver.t()]
  def list do
    Receiver |> order_by(:name) |> Repo.all() |> Enum.map(&expire/1)
  end

  @spec get(String.t()) :: Receiver.t() | nil
  def get(name) do
    case Repo.get_by(Receiver, name: name) do
      nil -> nil
      receiver -> expire(receiver)
    end
  end

  @spec online?(String.t()) :: boolean()
  def online?(name) do
    case get(name) do
      nil -> false
      receiver -> receiver.online
    end
  end

  @spec set_online(String.t(), boolean()) :: {:ok, Receiver.t()} | {:error, :not_found}
  def set_online(name, online?) when is_boolean(online?) do
    case Repo.get_by(Receiver, name: name) do
      nil ->
        {:error, :not_found}

      receiver ->
        until =
          if online? do
            nil
          else
            DateTime.utc_now() |> DateTime.add(@offline_seconds) |> DateTime.truncate(:second)
          end

        {:ok, updated} =
          receiver
          |> Ecto.Changeset.change(online: online?, offline_until: until)
          |> Repo.update()

        Events.broadcast([:dtq, :console, :demo_changed], %{receiver: name})
        {:ok, updated}
    end
  end

  defp expire(%Receiver{online: false, offline_until: %DateTime{} = until} = receiver) do
    if DateTime.compare(until, DateTime.utc_now()) == :lt do
      {:ok, updated} =
        receiver |> Ecto.Changeset.change(online: true, offline_until: nil) |> Repo.update()

      Events.broadcast([:dtq, :console, :demo_changed], %{receiver: receiver.name})
      updated
    else
      receiver
    end
  end

  defp expire(receiver), do: receiver
end
