defmodule DistributedTaskQueueWeb.WebhookController do
  use DistributedTaskQueueWeb, :controller

  alias DistributedTaskQueue.Webhooks
  alias DistributedTaskQueueWeb.{ChangesetErrors, JobController}

  def create(conn, params) do
    case Webhooks.enqueue(params) do
      {:ok, job} ->
        conn |> put_status(:created) |> json(%{data: JobController.job_json(job)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: ChangesetErrors.format(changeset)})
    end
  end
end
