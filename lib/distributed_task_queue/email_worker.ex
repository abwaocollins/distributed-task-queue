defmodule DistributedTaskQueue.EmailWorker do
  @behaviour DistributedTaskQueue.Worker

  def perform(payload) do
    # Implementation for sending emails
    IO.inspect("Sending email with payload: #{inspect(payload)}")
    :ok
  end
end
