defmodule DistributedTaskQueue.EmailWorker do
  @behaviour DistributedTaskQueue.Worker

  require Logger

  def perform(payload) do
    # Implementation for sending emails
    Logger.info("Sending email with payload: #{inspect(payload)}")
    :ok
  end
end
