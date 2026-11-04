defmodule DistributedTaskQueue.DemoWorker do
  @moduledoc """
  Stand-in work for the public demo: sleeps a while, and sometimes fails, so
  the dashboard always has jobs running, retrying and landing in the dead
  letter queue.

  Payload (all optional):

    * `"min_ms"` / `"max_ms"` — sleep range, default 300–3000
    * `"failure_rate"` — chance of returning an error, 0.0–1.0, default 0.1
    * `"fan_out"` — instead of sleeping, enqueue this many child jobs on
      `"fan_out_queue"` (default `"demo"`), each with this job's other settings
  """
  @behaviour DistributedTaskQueue.Worker

  @impl true
  def perform(%{"fan_out" => count} = payload) when is_integer(count) and count > 0 do
    queue = Map.get(payload, "fan_out_queue", "demo")
    child = Map.drop(payload, ["fan_out", "fan_out_queue"])

    Enum.each(1..count, fn _ ->
      DistributedTaskQueue.add_job(queue, %{
        "worker_module" => inspect(__MODULE__),
        "payload" => child,
        "max_attempts" => Map.get(payload, "child_max_attempts", 2)
      })
    end)

    :ok
  end

  def perform(payload) do
    min = Map.get(payload, "min_ms", 300)
    max = Map.get(payload, "max_ms", 3_000)
    Process.sleep(min + :rand.uniform(max(max - min, 0) + 1) - 1)

    if :rand.uniform() < Map.get(payload, "failure_rate", 0.1),
      do: {:error, "simulated failure (demo)"},
      else: :ok
  end
end
