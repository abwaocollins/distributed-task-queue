defmodule DistributedTaskQueueTest do
  use ExUnit.Case

  test "application starts" do
    assert :ok == :application.ensure_started(:distributed_task_queue)
  end
end
