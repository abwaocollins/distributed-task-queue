defmodule DistributedTaskQueueWeb.JobController do
  use DistributedTaskQueueWeb, :controller

  def index(conn, params) do
    jobs = DistributedTaskQueue.list_jobs_filtered(params)
    json(conn, %{data: Enum.map(jobs, &job_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case DistributedTaskQueue.get_job(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      job -> json(conn, %{data: job_json(job)})
    end
  end

  def create(conn, params) do
    queue_name = params["queue_name"] || params[:queue_name]
    case DistributedTaskQueue.add_job(queue_name, params) do
      {:ok, job} ->
        conn |> put_status(:created) |> json(%{data: job_json(job)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case DistributedTaskQueue.delete_job(id) do
      {:ok, job} ->
        json(conn, %{data: job_json(job)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :job_running} ->
        conn |> put_status(:conflict) |> json(%{error: "job is currently running"})
    end
  end

  def requeue(conn, %{"id" => id}) do
    case DistributedTaskQueue.requeue_dead_letter_job(id) do
      {:ok, job} ->
        json(conn, %{data: job_json(job)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :not_dead_letter} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "job is not a dead-letter job"})
    end
  end

  def requeue_all(conn, _params) do
    {:ok, count} = DistributedTaskQueue.requeue_all_dead_letter_jobs()
    json(conn, %{data: %{requeued: count}})
  end

  defp job_json(job) do
    %{
      id: job.id,
      queue_name: job.queue_name,
      worker_module: job.worker_module,
      payload: job.payload,
      status: job.status,
      attempts: job.attempts,
      max_attempts: job.max_attempts,
      error_message: job.error_message,
      scheduled_at: format_dt(job.scheduled_at),
      started_at: format_dt(job.started_at),
      completed_at: format_dt(job.completed_at),
      attempted_by: job.attempted_by,
      inserted_at: format_naive_dt(job.inserted_at)
    }
  end

  defp format_dt(nil), do: nil
  defp format_dt(dt), do: DateTime.to_iso8601(dt)

  defp format_naive_dt(nil), do: nil
  defp format_naive_dt(dt), do: NaiveDateTime.to_iso8601(dt)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
