defmodule DistributedTaskQueue.QueueManager do
  use GenServer, restart: :transient
  alias DistributedTaskQueue.{Worker, QueueCache}

  @poll_interval 5_000

  def start_link({queue_name, max_concurrency}) do
    GenServer.start_link(__MODULE__,
      %{queue: queue_name, max: max_concurrency, running: 0},
      name: via(queue_name)
    )
  end

  @doc """
  Ask a running manager to look for work now instead of at its next poll.

  Returns `:ok`, or `:not_running` if the manager is gone — including one that
  was already on its way out because it had found its queue empty. That case is
  why this is a call rather than a plain `send/2`: a message sent to a manager
  that is stopping is silently lost, and the job that prompted it would sit
  `pending` until something else woke the queue.
  """
  def wake(pid) do
    GenServer.call(pid, :wake)
  catch
    :exit, _ -> :not_running
  end

  @doc """
  Change the number of jobs this manager runs at once, without restarting it.

  Growing frees new slots immediately. Shrinking never interrupts a running job:
  slots above the new limit are retired as their jobs finish.
  """
  def resize(queue_name, max) do
    case Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue_name) do
      [{pid, _}] -> GenServer.cast(pid, {:resize, max})
      [] -> :ok
    end
  end

  @doc """
  Ids of the jobs this node's manager for `queue_name` is running right now.

  Lets the reaper tell a job that is merely slow from one whose worker is gone.
  Empty when the queue has no manager here.
  """
  def running_job_ids(queue_name) do
    case Registry.lookup(DistributedTaskQueue.WorkerRegistry, queue_name) do
      [{pid, _}] -> GenServer.call(pid, :running_job_ids)
      [] -> MapSet.new()
    end
  catch
    :exit, _ -> MapSet.new()
  end

  def init(%{max: max} = state) do
    Process.flag(:trap_exit, true)
    # Look for work straight away. The manager is started because something
    # just became claimable; waiting a full poll interval only delays it.
    send(self(), :poll)
    {:ok, Map.merge(state, %{free_slots: MapSet.new(1..max//1), task_slots: %{}})}
  end

  def handle_call(:running_job_ids, _from, state) do
    ids = state.task_slots |> Map.values() |> MapSet.new(fn {_pid, job_id} -> job_id end)
    {:reply, ids, state}
  end

  def handle_call(:wake, _from, state) do
    send(self(), :poll)
    {:reply, :ok, state}
  end

  def handle_cast({:resize, max}, state) do
    busy = state.task_slots |> Map.keys() |> MapSet.new()
    free_slots = MapSet.difference(MapSet.new(1..max//1), busy)

    send(self(), :poll)
    {:noreply, %{state | max: max, free_slots: free_slots}}
  end

  def handle_info(:poll, state) do
    if paused?(state.queue) do
      schedule_poll()
      {:noreply, state}
    else
      do_poll(state)
    end
  end

  # Job finished — return slot and poll immediately
  def handle_info({:job_done, slot, _result}, state) do
    send(self(), :poll)

    {:noreply, %{state |
      running: state.running - 1,
      free_slots: return_slot(state.free_slots, slot, state.max),
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
          free_slots: return_slot(state.free_slots, slot, state.max),
          task_slots: task_slots
        }
      else
        state
      end

    {:noreply, new_state}
  end

  # Slots available — try to claim a job
  defp do_poll(%{running: running, max: max} = state) when running < max do
    slot = Enum.min(state.free_slots)

    case DistributedTaskQueue.claim_job(state.queue, slot) do
      {:ok, job} ->
        {:ok, pid} = spawn_job(job, slot)

        new_state = %{state |
          running: running + 1,
          free_slots: MapSet.delete(state.free_slots, slot),
          task_slots: Map.put(state.task_slots, slot, {pid, job.id})
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
        {:noreply, state}
    end
  end

  # All slots busy — wait for a job to finish
  defp do_poll(state), do: {:noreply, state}

  defp paused?(queue_name) do
    case QueueCache.get(queue_name) do
      %{paused: true} -> true
      _ -> false
    end
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

  # A slot above the current limit belongs to a job that was already running
  # when the queue was resized down, so it is retired rather than reused.
  defp return_slot(free_slots, slot, max) when slot > max, do: free_slots
  defp return_slot(free_slots, slot, _max), do: MapSet.put(free_slots, slot)

  defp pop_by_pid(task_slots, pid) do
    case Enum.find(task_slots, fn {_, {p, _job_id}} -> p == pid end) do
      {slot, _} -> {slot, Map.delete(task_slots, slot)}
      nil -> {nil, task_slots}
    end
  end

  defp via(queue_name) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, queue_name}}
  end
end
