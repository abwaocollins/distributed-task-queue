defmodule DistributedTaskQueue.QueueManager do
  use GenServer, restart: :transient
  alias DistributedTaskQueue.Worker

  @poll_interval 5_000

  def start_link({queue_name, max_concurrency}) do
    GenServer.start_link(__MODULE__,
      %{queue: queue_name, max: max_concurrency, running: 0},
      name: via(queue_name)
    )
  end

  def init(state) do
    # Trap exits so task crashes arrive as {:EXIT} messages rather than killing the manager.
    Process.flag(:trap_exit, true)
    schedule_poll()
    {:ok, state}
  end

  # Under capacity — try to claim a job
  def handle_info(:poll, %{running: running, max: max} = state) when running < max do
    worker_id = worker_id(state.queue)

    case DistributedTaskQueue.claim_job(state.queue, worker_id) do
      {:ok, job} ->
        spawn_job(job)
        new_state = %{state | running: running + 1}
        if new_state.running < new_state.max, do: send(self(), :poll)
        {:noreply, new_state}

      {:error, :no_jobs} when running == 0 ->
        case DistributedTaskQueue.next_retryable_delay(state.queue) do
          nil ->
            {:stop, :normal, state}

          delay_ms ->
            # Retryable jobs exist — wake up when the earliest one becomes claimable.
            Process.send_after(self(), :poll, max(delay_ms, @poll_interval))
            {:noreply, state}
        end

      {:error, :no_jobs} ->
        # Jobs still running — each {:job_done} will trigger the next :poll
        {:noreply, state}
    end
  end

  # At max capacity — wait for a slot to free up
  def handle_info(:poll, state), do: {:noreply, state}

  # A job finished — free the slot and poll immediately
  def handle_info({:job_done, _result}, state) do
    send(self(), :poll)
    {:noreply, %{state | running: state.running - 1}}
  end

  # Task exited normally after sending {:job_done} — nothing to do
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Task crashed without sending {:job_done} — free the slot and recover
  def handle_info({:EXIT, _pid, _reason}, state) do
    send(self(), :poll)
    {:noreply, %{state | running: max(0, state.running - 1)}}
  end

  defp spawn_job(job) do
    manager = self()

    Task.start_link(fn ->
      result = Worker.run_job(job)
      send(manager, {:job_done, result})
    end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  # Stable integer ID per queue name — avoids hardcoding a single global worker_id.
  defp worker_id(queue_name), do: :erlang.phash2(queue_name)

  defp via(queue_name) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, queue_name}}
  end
end
