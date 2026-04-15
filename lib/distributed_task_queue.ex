defmodule DistributedTaskQueue do
  @moduledoc """
  DistributedTaskQueue keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  alias DistributedTaskQueue.WorkerSupervisor
  alias DistributedTaskQueue.Repo
  alias DistributedTaskQueue.{Job, Queue}
  import Ecto.Query

  #Add a job to the database
  def add_job(queue_name, job_attrs) do
    %Job{}
    |> Job.changeset(Map.merge(job_attrs, %{"queue_name" => queue_name}))
    |> Repo.insert()
  end

  #Add a queue to the database
  def add_queue(queue_name) do
    %Queue{}
    |> Queue.changeset(%{"name" => queue_name})
    |> Repo.insert()
  end

  #list all jobs

  def list_jobs do
    Repo.all(Job)
  end

  def get_job(job_id) do
    Repo.get(Job, job_id)
  end

  #list all queues
  def list_queues do
    Repo.all(Queue)
  end

  #list all pending jobs
  def list_pending_jobs do
    query = from j in Job, where: j.status == "pending"
    Repo.all(query)
  end

  # list all jobs that are scheduled to run in the future
  def list_scheduled_jobs do
    query = from j in Job, where: j.scheduled_at > ^DateTime.utc_now()
    Repo.all(query)
  end

  #list all jobs in a specific queue
  def list_jobs_in_queue(queue_name) do
    query = from j in Job, where: j.queue_name == ^queue_name
    Repo.all(query)
  end

  # list all jobs processed by a specific worker (audit)
  def list_jobs_for_worker(worker_id) do
    query = from j in Job,
            where: j.worker_id == ^worker_id,
            order_by: [asc: j.inserted_at]
    Repo.all(query)
  end

  def get_queue(queue_name) do
    Repo.get_by(Queue, name: queue_name)
  end

  # Atomically claim one available job in a queue for a worker
  def claim_job(queue_name, worker_id) do
    now = DateTime.utc_now()

    subquery = from j in Job,
      where: j.queue_name == ^queue_name
        and j.status in ["pending", "retryable"]
        and is_nil(j.worker_id)
        and (is_nil(j.scheduled_at) or j.scheduled_at <= ^now),
      order_by: [asc: j.inserted_at],
      limit: 1,
      select: j.id

    {_count, jobs} = Repo.update_all(
      from(j in Job, where: j.id in subquery(subquery)),
      [set: [worker_id: worker_id, status: "started", started_at: now]],
      returning: true
    )

    case jobs do
      [job] -> {:ok, job}
      [] -> {:error, :no_jobs}
    end
  end

  # update job status
  def update_job_status(job_id, new_status) do
    job = Repo.get(Job, job_id)
    if job do
      extra = case new_status do
        "started"   -> %{"started_at" => DateTime.utc_now()}
        "completed" -> %{"completed_at" => DateTime.utc_now()}
        "discarded" -> %{"discarded_at" => DateTime.utc_now()}
        "retryable" -> %{"error_message" => "Job failed", "attempts" => job.attempts + 1, "next_retry_at" => DateTime.add(DateTime.utc_now(), 60, :second)}
        _ -> %{}
      end
      job
      |> Job.changeset(Map.merge(extra, %{"status" => new_status}))
      |> Repo.update()
    else
      {:error, "Job not found"}
    end
  end

  #soft delete a job
  def delete_job(job_id) do
    job = Repo.get(Job, job_id)
    if job do
      job
      |> Job.changeset(%{"deleted_at" => DateTime.utc_now(), "status" => "deleted"})
      |> Repo.update()
    else
      {:error, "Job not found"}
    end
  end

  #permanently delete a job
  def hard_delete_job(job_id) do
    job = Repo.get(Job, job_id)
    if job do
      Repo.delete(job)
    else
      {:error, "Job not found"}
    end
  end

  def start_queue(queue_name) do
    case get_queue(queue_name) do
      nil -> {:error, :queue_not_found}
      queue -> WorkerSupervisor.start_queue(queue_name, queue.max_concurrent_jobs)
    end
  end
end
