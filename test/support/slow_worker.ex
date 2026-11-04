defmodule DistributedTaskQueue.Test.SlowWorker do
  @moduledoc "Test worker that sleeps for `payload[\"sleep_ms\"]`, to hold a slot open."
  @behaviour DistributedTaskQueue.Worker

  def perform(%{"sleep_ms" => ms}) do
    Process.sleep(ms)
    :ok
  end
end
