defmodule DistributedTaskQueue.QueueCacheTest do
  use ExUnit.Case, async: false

  alias DistributedTaskQueue.{QueueCache, Queue}

  setup do
    QueueCache.all() |> Enum.each(&QueueCache.delete(&1.name))
    :ok
  end

  test "returns nil for an unknown queue" do
    assert QueueCache.get("does-not-exist") == nil
  end

  test "put and get a queue" do
    queue = %Queue{name: "test-q", max_concurrent_jobs: 5}
    QueueCache.put(queue)
    assert QueueCache.get("test-q") == queue
  end

  test "put overwrites an existing entry" do
    queue = %Queue{name: "overwrite-q", max_concurrent_jobs: 5}
    QueueCache.put(queue)
    QueueCache.put(%{queue | max_concurrent_jobs: 10})
    assert QueueCache.get("overwrite-q").max_concurrent_jobs == 10
  end

  test "delete removes an entry" do
    queue = %Queue{name: "delete-q", max_concurrent_jobs: 5}
    QueueCache.put(queue)
    QueueCache.delete("delete-q")
    assert QueueCache.get("delete-q") == nil
  end

  test "all returns every cached queue" do
    QueueCache.put(%Queue{name: "all-q1", max_concurrent_jobs: 2})
    QueueCache.put(%Queue{name: "all-q2", max_concurrent_jobs: 3})
    names = QueueCache.all() |> Enum.map(& &1.name) |> Enum.sort()
    assert "all-q1" in names
    assert "all-q2" in names
  end
end
