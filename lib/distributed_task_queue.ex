defmodule DistributedTaskQueue do
  @moduledoc """
  DistributedTaskQueue keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  alias DistributedTaskQueue.WorkerSupervisor
  alias DistributedTaskQueue.Worker
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

  # list all pending jobs assigned to a specific worker
  def list_jobs_for_worker(worker_id) do
    query = from j in Job,
            where: j.worker_id == ^worker_id and j.status == "pending",
            order_by: [asc: j.inserted_at]
    Repo.all(query)
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

  def start_worker(id) do
    spec = {Worker, id}
    DynamicSupervisor.start_child(WorkerSupervisor, spec)
  end
end
