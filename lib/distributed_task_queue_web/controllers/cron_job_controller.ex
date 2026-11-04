defmodule DistributedTaskQueueWeb.CronJobController do
  use DistributedTaskQueueWeb, :controller

  alias DistributedTaskQueue.{CronJob, Webhooks}
  alias DistributedTaskQueueWeb.ChangesetErrors

  # Owned by the scheduler. `enabled` changes go through enable/disable, which
  # restart the schedule from now instead of firing a catch-up run.
  @scheduler_fields ~w(last_run_at next_run_at)
  @update_ignored ["enabled" | @scheduler_fields]

  def index(conn, _params) do
    json(conn, %{data: Enum.map(DistributedTaskQueue.list_cron_jobs(), &cron_json/1)})
  end

  def show(conn, %{"id" => id}) do
    with_cron(conn, id, &json(conn, %{data: cron_json(&1)}))
  end

  def create(conn, params) do
    {errors, attrs} = params |> Webhooks.cron_attrs() |> Map.pop("webhook_errors")

    with :ok <- check_webhook(%CronJob{}, attrs, errors),
         {:ok, cron} <- DistributedTaskQueue.create_cron_job(Map.drop(attrs, @scheduler_fields)) do
      conn |> put_status(:created) |> json(%{data: cron_json(cron)})
    else
      {:error, changeset} -> unprocessable(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_cron(conn, id, fn cron ->
      {errors, attrs} =
        params
        |> Map.drop(["id" | @update_ignored])
        |> Webhooks.cron_attrs()
        |> Map.pop("webhook_errors")

      with :ok <- check_webhook(cron, attrs, errors),
           {:ok, updated} <- DistributedTaskQueue.update_cron_job(cron, attrs) do
        json(conn, %{data: cron_json(updated)})
      else
        {:error, changeset} -> unprocessable(conn, changeset)
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_cron(conn, id, fn cron ->
      {:ok, deleted} = DistributedTaskQueue.delete_cron_job(cron)
      json(conn, %{data: cron_json(deleted)})
    end)
  end

  def enable(conn, %{"id" => id}) do
    with_cron(conn, id, fn cron ->
      {:ok, cron} = DistributedTaskQueue.enable_cron_job(cron)
      json(conn, %{data: cron_json(cron)})
    end)
  end

  def disable(conn, %{"id" => id}) do
    with_cron(conn, id, fn cron ->
      {:ok, cron} = DistributedTaskQueue.disable_cron_job(cron)
      json(conn, %{data: cron_json(cron)})
    end)
  end

  # An invalid webhook object is reported as errors on payload, alongside any
  # other problems with the cron itself.
  defp check_webhook(_cron, _attrs, nil), do: :ok

  defp check_webhook(cron, attrs, messages) do
    changeset =
      Enum.reduce(messages, CronJob.changeset(cron, attrs), fn msg, cs ->
        Ecto.Changeset.add_error(cs, :payload, msg)
      end)

    {:error, changeset}
  end

  defp with_cron(conn, id, fun) do
    case Integer.parse(to_string(id)) do
      {int, ""} ->
        case DistributedTaskQueue.get_cron_job(int) do
          nil -> not_found(conn)
          cron -> fun.(cron)
        end

      _ ->
        not_found(conn)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not found"})

  defp unprocessable(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: ChangesetErrors.format(changeset)})
  end

  defp cron_json(cron) do
    %{
      id: cron.id,
      name: cron.name,
      description: cron.description,
      queue_name: cron.queue_name,
      worker_module: cron.worker_module,
      payload: cron.payload,
      max_attempts: cron.max_attempts,
      cron_expression: cron.cron_expression,
      interval_seconds: cron.interval_seconds,
      timezone: cron.timezone,
      overlap: cron.overlap,
      enabled: cron.enabled,
      last_run_at: format_dt(cron.last_run_at),
      next_run_at: format_dt(cron.next_run_at)
    }
  end

  defp format_dt(nil), do: nil
  defp format_dt(dt), do: DateTime.to_iso8601(dt)
end
