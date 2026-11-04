defmodule DistributedTaskQueue.Demo.OrderWorker do
  @moduledoc """
  One order at the fictional Acme Store. Each order fans out into three
  webhooks, one to each demo receiver (payments, email, warehouse), so the
  demo shows a real-looking pipeline built only from webhook jobs.
  """
  @behaviour DistributedTaskQueue.Worker

  alias DistributedTaskQueue.Webhooks
  alias DistributedTaskQueue.Webhooks.Target

  @customers ~w(Amara Bilal Chen Dara Elena Farid)
  @receivers ~w(payments email warehouse)

  @impl true
  def perform(_payload) do
    order = order()

    # Stop at the first failure: the cron run is retried as a whole.
    Enum.reduce_while(@receivers, :ok, fn receiver, :ok ->
      attrs = %{
        "url" => Target.demo_receiver_url(receiver),
        "method" => "POST",
        "body" => order,
        "queue" => "webhooks"
      }

      case Webhooks.enqueue(attrs) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp order do
    %{
      "order_id" => "ACME-" <> Base.encode16(:crypto.strong_rand_bytes(3)),
      # 5.00 to 250.00 in whole cents, so the total never has stray decimals.
      "total" => (499 + :rand.uniform(24_501)) / 100,
      "customer" => Enum.random(@customers)
    }
  end
end
