defmodule DistributedTaskQueueWeb.JobController do
  use DistributedTaskQueueWeb, :controller

  alias DistributedTaskQueue.{Job, Webhooks}
  alias DistributedTaskQueueWeb.ChangesetErrors

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

    # A job naming the webhook worker gets the same request and target checks
    # as POST /api/webhooks, so this route can't be used to skip them.
    result =
      case Webhooks.validate_worker_attrs(params) do
        {:ok, attrs} -> DistributedTaskQueue.add_job(queue_name, attrs)
        {:error, messages} -> {:error, Webhooks.error_changeset(%Job{}, :payload, messages)}
      end

    case result do
      {:ok, job} ->
        conn |> put_status(:created) |> json(%{data: job_json(job)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: ChangesetErrors.format(changeset)})
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

  def retry(conn, %{"id" => id}) do
    case DistributedTaskQueue.retry_job(id) do
      {:ok, job} ->
        json(conn, %{data: job_json(job)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :job_running} ->
        conn |> put_status(:conflict) |> json(%{error: "job is currently running; stop it first"})

      {:error, :not_retryable} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "job cannot be retried"})
    end
  end

  def stop(conn, %{"id" => id}) do
    case DistributedTaskQueue.cancel_job(id) do
      {:ok, job} ->
        json(conn, %{data: job_json(job)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :already_finished} ->
        conn |> put_status(:conflict) |> json(%{error: "job has already finished"})
    end
  end

  def bulk(conn, %{"action" => action, "ids" => ids}) when is_list(ids) do
    # Bounded to bigint, or Postgrex raises on an id the column cannot hold.
    with true <- Enum.all?(ids, &(is_integer(&1) and &1 in 1..9_223_372_036_854_775_807)),
         {:ok, %{succeeded: succeeded, failed: failed}} <-
           DistributedTaskQueue.bulk_job_action(action, ids) do
      json(conn, %{
        data: %{
          succeeded: succeeded,
          failed: Enum.map(failed, fn {id, reason} -> %{id: id, error: bulk_error(reason)} end)
        }
      })
    else
      false ->
        bulk_unprocessable(conn, "ids must be a list of positive integer job ids")

      {:error, :unknown_action} ->
        bulk_unprocessable(
          conn,
          "action must be one of: #{Enum.join(DistributedTaskQueue.bulk_actions(), ", ")}"
        )

      {:error, :too_many} ->
        bulk_unprocessable(conn, "at most #{DistributedTaskQueue.max_bulk()} ids per request")
    end
  end

  def bulk(conn, _params),
    do: bulk_unprocessable(conn, ~s(expected {"action": ..., "ids": [...]}))

  defp bulk_unprocessable(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})

  defp bulk_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp bulk_error(_reason), do: "could_not_change"

  def requeue_all(conn, _params) do
    {:ok, count} = DistributedTaskQueue.requeue_all_dead_letter_jobs()
    json(conn, %{data: %{requeued: count}})
  end

  @doc false
  def job_json(%{worker_module: module} = job) do
    # Resolve rather than string-compare, so an "Elixir."-prefixed spelling of
    # the webhook worker is redacted too.
    if Webhooks.webhook_worker?(module) do
      job
      |> base_json()
      |> Map.put(:payload, Webhooks.redact_payload(job))
      |> Map.put(:deliveries, Enum.map(Webhooks.list_deliveries(job.id), &delivery_json/1))
    else
      base_json(job)
    end
  end

  defp delivery_json(d) do
    %{
      number: d.number,
      status_code: d.status_code,
      duration_ms: d.duration_ms,
      error: d.error,
      response_body: d.response_body,
      inserted_at: format_dt(d.inserted_at)
    }
  end

  defp base_json(job) do
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
end
