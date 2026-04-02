defmodule DistributedTaskQueue.Worker do
  use GenServer
  alias DistributedTaskQueue.{Job, Repo}
  import Ecto.Query
  @poll_interval 5_000

  def start_link(id) do
    GenServer.start_link(__MODULE__, %{id: id}, name: via(id))
  end

  # Fetch pending jobs assigned to this worker
  def fetch_jobs(worker_id) do
    GenServer.call(via(worker_id), :fetch_jobs)
  end

  # Handle the :fetch_jobs call
  def handle_call(:fetch_jobs, _from, state) do
    jobs = get_jobs_for_worker(state.id)
    {:reply, jobs, state}
  end

  defp via(id) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, id}}
  end

  defp get_jobs_for_worker(worker_id) do
    query = from j in Job,
            where: j.worker_id == ^worker_id and j.status == "pending",
            order_by: [asc: j.inserted_at]
    Repo.all(query)
  end

  def handle_info(:poll, state) do
    # Poll for new jobs assigned to this worker
    get_jobs_for_worker(state.id)
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, state}
  end

  def init(state) do
      Process.send_after(self(), :poll, @poll_interval)
      {:ok, state}

  end

end
