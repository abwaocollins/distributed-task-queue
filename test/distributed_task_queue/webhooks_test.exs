defmodule DistributedTaskQueue.WebhooksTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{Repo, Webhooks}

  describe "record_delivery/2" do
    test "numbers deliveries 1, 2, 3 and keeps counting after a requeue" do
      job = insert(:job)

      for _ <- 1..3 do
        {:ok, _} = Webhooks.record_delivery(job, %{method: "POST", url: "http://x"})
      end

      job |> Ecto.Changeset.change(attempts: 0) |> Repo.update!()

      {:ok, _} = Webhooks.record_delivery(job, %{method: "POST", url: "http://x"})

      assert Enum.map(Webhooks.list_deliveries(job.id), & &1.number) == [1, 2, 3, 4]
    end

    test "truncates and sanitises the response body" do
      job = insert(:job)
      body = String.duplicate("a", 5000) <> <<0xFF>> <> String.duplicate("b", 5000)

      {:ok, d} = Webhooks.record_delivery(job, %{response_body: body, status_code: 200})
      stored = hd(Webhooks.list_deliveries(job.id)).response_body

      assert byte_size(stored) <= 2048
      assert String.valid?(stored)
      assert d.response_body == stored
    end

    test "does not split a multi-byte codepoint at the limit" do
      job = insert(:job)
      body = String.duplicate("a", 2047) <> "é" <> "tail"

      {:ok, d} = Webhooks.record_delivery(job, %{response_body: body})

      assert d.response_body == String.duplicate("a", 2047)
      assert String.valid?(d.response_body)
    end

    test "replaces each invalid byte with U+FFFD" do
      job = insert(:job)

      {:ok, d} =
        Webhooks.record_delivery(job, %{response_body: "a" <> <<0xFF>> <> "b" <> <<0xC3>>})

      assert d.response_body == "a�b�"
    end

    test "strips NUL bytes from the response body, error and url" do
      job = insert(:job)

      assert {:ok, d} =
               Webhooks.record_delivery(job, %{
                 response_body: "ab" <> <<0>> <> "cd",
                 error: "bad" <> <<0>> <> "thing",
                 url: "http://x/" <> <<0>> <> "y"
               })

      assert d.response_body == "abcd"
      assert d.error == "badthing"
      assert d.url == "http://x/y"

      stored = hd(Webhooks.list_deliveries(job.id))
      refute String.contains?(stored.response_body, <<0>>)
      refute String.contains?(stored.error, <<0>>)
    end

    test "truncates a long error" do
      job = insert(:job)
      {:ok, d} = Webhooks.record_delivery(job, %{error: String.duplicate("e", 5000)})
      assert byte_size(d.error) == 2048
    end

    test "leaves a short body and a missing body alone" do
      job = insert(:job)
      {:ok, d1} = Webhooks.record_delivery(job, %{response_body: "ok"})
      {:ok, d2} = Webhooks.record_delivery(job, %{error: "timeout"})
      assert d1.response_body == "ok"
      assert d2.response_body == nil
    end
  end

  test "hard-deleting the job deletes its deliveries" do
    job = insert(:job)
    {:ok, _} = Webhooks.record_delivery(job, %{method: "GET"})

    Repo.delete!(job)

    assert Webhooks.list_deliveries(job.id) == []
  end

  describe "secret/0" do
    test "reads the configured secret" do
      old = Application.get_env(:distributed_task_queue, :webhooks)

      on_exit(fn ->
        if old,
          do: Application.put_env(:distributed_task_queue, :webhooks, old),
          else: Application.delete_env(:distributed_task_queue, :webhooks)
      end)

      Application.put_env(:distributed_task_queue, :webhooks, secret: "shh")
      assert Webhooks.secret() == "shh"

      Application.delete_env(:distributed_task_queue, :webhooks)
      assert Webhooks.secret() == nil
    end
  end
end
