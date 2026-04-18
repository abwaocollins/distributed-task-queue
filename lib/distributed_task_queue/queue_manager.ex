defmodule DistributedTaskQueue.QueueManager do
  use GenServer
  alias DistributedTaskQueue.Worker

  @poll_interval 5_000
  @manager_worker_id 1

  def start_link({queue_name, max_concurrency}) do
    GenServer.start_link(__MODULE__,
      %{queue: queue_name, max: max_concurrency, running: 0},
      name: via(queue_name)
    )
  end

  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  # Under capacity — try to claim a job
  def handle_info(:poll, %{running: running, max: max} = state) when running < max do
    case DistributedTaskQueue.claim_job(state.queue, @manager_worker_id) do
      {:ok, job} ->
        spawn_job(job)
        new_state = %{state | running: running + 1}
        # Still have capacity — try to fill more slots immediately
        if new_state.running < new_state.max, do: send(self(), :poll)
        {:noreply, new_state}

      {:error, :no_jobs} ->
        schedule_poll()
        {:noreply, state}
    end
  end

  # At max capacity — ignore poll, wait for a slot to free up
  def handle_info(:poll, state) do
    {:noreply, state}
  end

  # A job finished — free the slot and poll immediately
  def handle_info({:job_done, _result}, state) do
    send(self(), :poll)
    {:noreply, %{state | running: state.running - 1}}
  end

  defp spawn_job(job) do
    manager = self()
    Task.start(fn ->
      result = Worker.run_job(job)
      send(manager, {:job_done, result})
    end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp via(queue_name) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, queue_name}}
  end
end
