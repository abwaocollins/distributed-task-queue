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

  def execute_job(worker_id, job_id) do
    GenServer.cast(via(worker_id), {:execute_job, job_id})
  end

  # Handle the :fetch_jobs call
  def handle_call(:fetch_jobs, _from, state) do
    jobs = get_jobs_for_worker(state.id)
    {:reply, jobs, state}
  end

  def handle_cast({:execute_job, job_id}, state) do
    DistributedTaskQueue.update_job_status(job_id, "started")
    job = DistributedTaskQueue.get_job(job_id)
    run_job(job)

    # Execute the job
    {:noreply, state}
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

  defp via(id) do
    {:via, Registry, {DistributedTaskQueue.WorkerRegistry, id}}
  end

  defp get_jobs_for_worker(worker_id) do
    query = from j in Job,
            where: j.worker_id == ^worker_id and j.status in ["pending", "retryable"],
            order_by: [asc: j.inserted_at]
    Repo.all(query)
  end

  def run_job(job) do
    module = String.to_existing_atom(job.worker_module)

    try do
      apply(module, :perform, [job.args])
      DistributedTaskQueue.update_job_status(job.id, "completed")
    rescue
      e ->
        Exception.message(e)
        new_status = if job.attempts + 1 > job.max_attempts, do: "discarded", else: "retryable"
        DistributedTaskQueue.update_job_status(job.id, new_status)
    end
  end

end
