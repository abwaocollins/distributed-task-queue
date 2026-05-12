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

  def init(%{max: max} = state) do
    Process.flag(:trap_exit, true)
    schedule_poll()

    {:ok, Map.merge(state, %{free_slots: MapSet.new(1..max), task_slots: %{}})}
  end

  # Slots available — try to claim a job
  def handle_info(:poll, %{running: running, max: max} = state) when running < max do
    slot = Enum.min(state.free_slots)

    case DistributedTaskQueue.claim_job(state.queue, slot) do
      {:ok, job} ->
        {:ok, pid} = spawn_job(job, slot)

        new_state = %{state |
          running: running + 1,
          free_slots: MapSet.delete(state.free_slots, slot),
          task_slots: Map.put(state.task_slots, slot, pid)
        }

        if new_state.running < max, do: send(self(), :poll)
        {:noreply, new_state}

      {:error, :no_jobs} when running == 0 ->
        case DistributedTaskQueue.next_retryable_delay(state.queue) do
          nil ->
            {:stop, :normal, state}

          delay_ms ->
            Process.send_after(self(), :poll, max(delay_ms, @poll_interval))
            {:noreply, state}
        end

      {:error, :no_jobs} ->
        # Some tasks still running — each {:job_done} will trigger the next :poll
        {:noreply, state}
    end
  end

  # All slots busy — wait for a job to finish
  def handle_info(:poll, state), do: {:noreply, state}

  # Job finished — return slot and poll immediately
  def handle_info({:job_done, slot, _result}, state) do
    send(self(), :poll)

    {:noreply, %{state |
      running: state.running - 1,
      free_slots: MapSet.put(state.free_slots, slot),
      task_slots: Map.delete(state.task_slots, slot)
    }}
  end

  # Task exited normally after sending {:job_done} — slot already returned
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Task crashed without sending {:job_done} — recover the slot
  def handle_info({:EXIT, pid, _reason}, state) do
    {slot, task_slots} = pop_by_pid(state.task_slots, pid)

    new_state =
      if slot do
        send(self(), :poll)
        %{state |
          running: max(0, state.running - 1),
          free_slots: MapSet.put(state.free_slots, slot),
          task_slots: task_slots
        }
      else
        state
      end

    {:noreply, new_state}
  end

  defp spawn_job(job, slot) do
    manager = self()

    Task.start_link(fn ->
      result = Worker.run_job(job)
      send(manager, {:job_done, slot, result})
    end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  # Find and remove a task_slots entry by pid. O(n) but max_concurrency is small.
  defp pop_by_pid(task_slots, pid) do
    case Enum.find(task_slots, fn {_, p} -> p == pid end) do
      {slot, _} -> {slot, Map.delete(task_slots, slot)}
      nil -> {nil, task_slots}
    end
  end

  defp via(queue_name) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, queue_name}}
  end
end
