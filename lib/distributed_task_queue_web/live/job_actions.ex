defmodule DistributedTaskQueueWeb.JobActions do
  @moduledoc """
  Retry and Stop for the job list and the job page: which jobs offer each
  button, and the flash each outcome leaves.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias DistributedTaskQueue.Events
  alias DistributedTaskQueueWeb.Selection

  @doc "Whether a job offers Retry. Waiting jobs offer it too, as \"run now\"."
  def retryable?(%{status: status}),
    do: status in ~w(pending retryable completed discarded cancelled)

  @doc "Whether a job offers Stop."
  def stoppable?(%{status: status}), do: status in ~w(pending retryable started)

  @doc "Retry's label: a waiting job is run early, a finished one is run again."
  def retry_label(%{status: status}) when status in ~w(pending retryable), do: "Run now"
  def retry_label(_job), do: "Retry"

  @doc """
  One line for a bulk action's outcome, e.g. "Retried 3 jobs. Skipped 1: running."
  """
  def bulk_summary(action, result),
    do: Selection.summary(bulk_verb(action), {"job", "jobs"}, result, &skip_reason/1)

  defp bulk_verb("retry"), do: "Retried"
  defp bulk_verb("stop"), do: "Stopped"
  defp bulk_verb("delete"), do: "Deleted"
  defp bulk_verb("requeue"), do: "Requeued"

  defp skip_reason(:job_running), do: "running"
  defp skip_reason(:already_finished), do: "already finished"
  defp skip_reason(:not_retryable), do: "not retryable"
  defp skip_reason(:not_dead_letter), do: "no longer dead-lettered"
  defp skip_reason(:not_found), do: "gone"
  defp skip_reason(_), do: "could not be changed"

  def retry(socket, id) do
    case DistributedTaskQueue.retry_job(id) do
      {:ok, job} ->
        Events.broadcast([:dtq, :console, :job_retried], %{job_id: job.id})
        put_flash(socket, :info, "Job ##{job.id} will run again.")

      {:error, :job_running} ->
        put_flash(socket, :error, "Job ##{id} is running. Stop it first to run it again.")

      {:error, :not_found} ->
        put_flash(socket, :error, "Job ##{id} no longer exists.")

      {:error, :not_retryable} ->
        put_flash(socket, :error, "Job ##{id} cannot be retried.")
    end
  end

  def stop(socket, id) do
    case DistributedTaskQueue.cancel_job(id) do
      {:ok, job} ->
        Events.broadcast([:dtq, :console, :job_stopped], %{job_id: job.id})
        put_flash(socket, :info, "Job ##{job.id} stopped.")

      {:error, :already_finished} ->
        put_flash(socket, :error, "Job ##{id} had already finished.")

      {:error, :not_found} ->
        put_flash(socket, :error, "Job ##{id} no longer exists.")
    end
  end
end
