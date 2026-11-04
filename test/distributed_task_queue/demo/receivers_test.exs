defmodule DistributedTaskQueue.Demo.ReceiversTest do
  use DistributedTaskQueue.DataCase, async: true

  alias DistributedTaskQueue.Demo.{Receiver, Receivers}
  alias DistributedTaskQueue.Repo

  setup do
    Receivers.ensure_all()
    :ok
  end

  test "ensure_all is idempotent and keeps edits" do
    Receiver
    |> Repo.get_by!(name: "email")
    |> Ecto.Changeset.change(failure_rate: 0.9)
    |> Repo.update!()

    assert :ok = Receivers.ensure_all()
    assert Repo.aggregate(Receiver, :count) == 3
    assert Repo.get_by!(Receiver, name: "email").failure_rate == 0.9
  end

  test "set_online(false) sets offline_until 5 minutes ahead" do
    assert {:ok, receiver} = Receivers.set_online("payments", false)
    refute receiver.online
    assert DateTime.diff(receiver.offline_until, DateTime.utc_now()) in 295..300
    refute Receivers.online?("payments")
  end

  test "set_online(true) clears offline_until" do
    {:ok, _} = Receivers.set_online("payments", false)
    assert {:ok, %{online: true, offline_until: nil}} = Receivers.set_online("payments", true)
  end

  test "offline receivers come back on their own after 5 minutes" do
    past = DateTime.utc_now() |> DateTime.add(-10) |> DateTime.truncate(:second)

    Receiver
    |> Repo.get_by!(name: "warehouse")
    |> Ecto.Changeset.change(online: false, offline_until: past)
    |> Repo.update!()

    assert Receivers.online?("warehouse")
    assert %{online: true, offline_until: nil} = Repo.get_by!(Receiver, name: "warehouse")
  end

  test "unknown names" do
    refute Receivers.online?("nope")
    assert {:error, :not_found} = Receivers.set_online("nope", false)
  end
end
