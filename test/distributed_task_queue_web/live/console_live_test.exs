defmodule DistributedTaskQueueWeb.ConsoleLiveTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DistributedTaskQueue.{CronJob, Job, Queue, QueueCache, Repo, WorkerSupervisor}

  defp cleanup_queue(name) do
    on_exit(fn ->
      WorkerSupervisor.stop_queue(name)
      QueueCache.delete(name)
    end)
  end

  describe "navigation" do
    test "every page renders and marks itself active in the nav", %{conn: conn} do
      for {path, label} <- [
            {~p"/", "Overview"},
            {~p"/queues", "Queues"},
            {~p"/jobs", "Jobs"},
            {~p"/dead-letter", "Dead letter"},
            {~p"/cron", "Cron"}
          ] do
        {:ok, view, _html} = live(conn, path)
        assert view |> element(~s(nav a[aria-current="page"])) |> render() =~ label
      end
    end

    test "the nav shows the dead-letter count", %{conn: conn} do
      insert(:job, status: "discarded", dead_letter: true)
      {:ok, view, _html} = live(conn, ~p"/queues")
      assert view |> element("#nav-dead-count") |> render() =~ "1"
    end
  end

  describe "overview" do
    test "says so when nothing needs attention", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Nothing needs attention"
    end

    test "flags crons pointing at a missing queue, orphans and dead letters", %{conn: conn} do
      queue = insert(:queue, name: "billing")
      insert(:job, queue_name: queue.name, status: "started")
      insert(:job, status: "discarded", dead_letter: true, error_message: "boom")
      insert(:cron_job, name: "nightly", queue_name: "ghost")

      {:ok, view, _html} = live(conn, ~p"/")
      attention = view |> element("#attention") |> render()

      assert attention =~ "Cron nightly targets queue ghost"
      assert attention =~ "marked running in billing"
      assert attention =~ "exhausted their attempts"
    end

    test "lists recent failures with their error", %{conn: conn} do
      job = insert(:job, status: "retryable", attempts: 1, error_message: "smtp timeout")
      {:ok, view, _html} = live(conn, ~p"/")
      assert view |> element("#failure-#{job.id}") |> render() =~ "smtp timeout"
    end

    test "a job telemetry event refreshes the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      job = insert(:job, status: "retryable", error_message: "late failure")

      :telemetry.execute([:dtq, :job, :failed], %{duration: 5}, %{
        job_id: job.id,
        queue_name: job.queue_name,
        worker_module: job.worker_module,
        reason: "late failure"
      })

      assert_eventually(fn -> has_element?(view, "#failure-#{job.id}") end)
    end
  end

  describe "queues" do
    test "creates a queue, showing validation errors first", %{conn: conn} do
      cleanup_queue("reports")
      {:ok, view, _html} = live(conn, ~p"/queues/new")

      html =
        view
        |> form("#queue-form", queue: %{name: "reports", max_concurrent_jobs: 0})
        |> render_change()

      assert html =~ "must be greater than 0"

      view
      |> form("#queue-form", queue: %{name: "reports", max_concurrent_jobs: 4})
      |> render_submit()

      assert_patch(view, ~p"/queues")
      assert render(view) =~ "Queue reports created"
      assert %Queue{max_concurrent_jobs: 4} = DistributedTaskQueue.get_queue("reports")
    end

    test "rejects a duplicate name", %{conn: conn} do
      insert(:queue, name: "emails")
      {:ok, view, _html} = live(conn, ~p"/queues/new")

      html =
        view
        |> form("#queue-form", queue: %{name: "emails", max_concurrent_jobs: 2})
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "edits description and concurrency", %{conn: conn} do
      queue = insert(:queue, name: "imports")
      cleanup_queue(queue.name)
      {:ok, view, _html} = live(conn, ~p"/queues/imports/edit")

      view
      |> form("#queue-form", queue: %{description: "CSV imports", max_concurrent_jobs: 7})
      |> render_submit()

      assert %Queue{description: "CSV imports", max_concurrent_jobs: 7} =
               Repo.reload!(queue)
    end

    test "pauses, resumes and deletes", %{conn: conn} do
      queue = insert(:queue, name: "reports")
      cleanup_queue(queue.name)
      {:ok, view, _html} = live(conn, ~p"/queues")

      view |> element("#queue-reports button", "Pause") |> render_click()
      assert Repo.reload!(queue).paused
      assert view |> element("#queue-reports") |> render() =~ "Paused"

      view |> element("#queue-reports button", "Resume") |> render_click()
      refute Repo.reload!(queue).paused

      view |> element("#queue-reports button", "Delete") |> render_click()
      refute has_element?(view, "#queue-reports")
      assert is_nil(DistributedTaskQueue.get_queue("reports"))
    end
  end

  describe "jobs" do
    test "filters by status, queue, errors and search", %{conn: conn} do
      emails = insert(:queue, name: "emails")
      done = insert(:job, queue_name: emails.name, status: "completed")
      failing = insert(:job, status: "retryable", error_message: "connection refused")

      {:ok, view, _html} = live(conn, ~p"/jobs")
      assert has_element?(view, "#job-#{done.id}")
      assert has_element?(view, "#job-#{failing.id}")

      view |> form("#job-filters", filters: %{status: "retryable"}) |> render_change()
      assert_patch(view, ~p"/jobs?status=retryable")
      refute has_element?(view, "#job-#{done.id}")
      assert has_element?(view, "#job-#{failing.id}")

      {:ok, view, _html} = live(conn, ~p"/jobs?queue=emails")
      assert has_element?(view, "#job-#{done.id}")
      refute has_element?(view, "#job-#{failing.id}")

      {:ok, view, _html} = live(conn, ~p"/jobs?errors=true")
      refute has_element?(view, "#job-#{done.id}")
      assert view |> element("#job-#{failing.id}") |> render() =~ "connection refused"

      {:ok, view, _html} = live(conn, ~p"/jobs?q=refused")
      assert has_element?(view, "#job-#{failing.id}")
      refute has_element?(view, "#job-#{done.id}")

      {:ok, _view, html} = live(conn, ~p"/jobs?q=no-such-thing")
      assert html =~ "No jobs match these filters"
    end

    test "creates a job, rejecting invalid JSON and bad module names", %{conn: conn} do
      queue = insert(:queue, name: "emails")
      cleanup_queue(queue.name)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      html =
        view
        |> form("#job-form",
          job: %{queue_name: "emails", worker_module: "not a module", payload: "{oops"}
        )
        |> render_change()

      assert html =~ "is not valid JSON"
      assert html =~ "is not a valid Elixir module name"

      html =
        view
        |> form("#job-form",
          job: %{queue_name: "emails", worker_module: "Mod", payload: "[1, 2]"}
        )
        |> render_change()

      assert html =~ "must be a JSON object"

      view
      |> form("#job-form",
        job: %{
          queue_name: "emails",
          worker_module: "DistributedTaskQueue.EmailWorker",
          payload: ~s({"to": "ops@example.com"}),
          max_attempts: 5
        }
      )
      |> render_submit()

      assert [job] = Repo.all(Job)
      assert job.payload == %{"to" => "ops@example.com"}
      assert job.max_attempts == 5
      assert render(view) =~ "Job ##{job.id} enqueued on emails"
    end

    test "deletes a job", %{conn: conn} do
      job = insert(:job, status: "completed")
      {:ok, view, _html} = live(conn, ~p"/jobs")

      view |> element("#job-#{job.id} button", "Delete") |> render_click()

      refute has_element?(view, "#job-#{job.id}")
      assert Repo.reload!(job).deleted_at
    end

    test "detail page shows the full error and payload", %{conn: conn} do
      job =
        insert(:job,
          status: "retryable",
          attempts: 1,
          error_message: "** (RuntimeError) upstream 503",
          payload: %{"invoice" => 42}
        )

      {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

      assert view |> element("#job-error") |> render() =~ "upstream 503"
      assert view |> element("#job-error") |> render() =~ "will be retried"
      assert view |> element("#job-payload") |> render() =~ "&quot;invoice&quot;: 42"
    end

    test "detail page for a missing job says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/jobs/999999")
      assert html =~ "does not exist or was deleted"
    end
  end

  describe "dead letter" do
    test "filters by queue and requeues one job", %{conn: conn} do
      a = insert(:queue, name: "a")
      cleanup_queue(a.name)
      in_a = insert(:job, queue_name: a.name, status: "discarded", dead_letter: true)
      other = insert(:job, status: "discarded", dead_letter: true)

      {:ok, view, _html} = live(conn, ~p"/dead-letter?queue=a")
      assert has_element?(view, "#dead-#{in_a.id}")
      refute has_element?(view, "#dead-#{other.id}")

      view |> element("#dead-#{in_a.id} button", "Requeue") |> render_click()

      refute has_element?(view, "#dead-#{in_a.id}")
      assert %Job{status: "pending", dead_letter: false} = Repo.reload!(in_a)
    end

    test "requeue only touches the jobs the filter shows", %{conn: conn} do
      a = insert(:queue, name: "a")
      cleanup_queue(a.name)
      in_a = insert(:job, queue_name: a.name, status: "discarded", dead_letter: true)
      other = insert(:job, status: "discarded", dead_letter: true)

      {:ok, view, _html} = live(conn, ~p"/dead-letter?queue=a")
      html = view |> element("#requeue-matching") |> render_click()

      assert html =~ "Requeued 1 job"
      refute Repo.reload!(in_a).dead_letter
      assert Repo.reload!(other).dead_letter
    end
  end

  describe "cron" do
    test "creates an interval cron job", %{conn: conn} do
      insert(:queue, name: "emails")
      {:ok, view, _html} = live(conn, ~p"/cron/new")

      view
      |> form("#cron-form", cron: %{schedule_type: "interval"})
      |> render_change()

      view
      |> form("#cron-form",
        cron: %{
          name: "digest",
          queue_name: "emails",
          worker_module: "DistributedTaskQueue.EmailWorker",
          schedule_type: "interval",
          interval_seconds: 600,
          payload: ~s({"kind": "digest"}),
          max_attempts: 2
        }
      )
      |> render_submit()

      assert %CronJob{interval_seconds: 600, cron_expression: nil, next_run_at: %DateTime{}} =
               Repo.get_by!(CronJob, name: "digest")

      assert render(view) =~ "Cron job digest saved"
    end

    test "shows cron expression and timezone errors inline", %{conn: conn} do
      insert(:queue, name: "emails")
      {:ok, view, _html} = live(conn, ~p"/cron/new")

      html =
        view
        |> form("#cron-form",
          cron: %{
            name: "bad",
            queue_name: "emails",
            worker_module: "DistributedTaskQueue.EmailWorker",
            schedule_type: "cron",
            cron_expression: "not cron",
            timezone: "Mars/Olympus"
          }
        )
        |> render_submit()

      assert html =~ "is not a valid cron expression"
      refute Repo.get_by(CronJob, name: "bad")
    end

    test "edits, disables and deletes", %{conn: conn} do
      cron = insert(:cron_job, name: "cleanup", interval_seconds: 300)
      {:ok, view, _html} = live(conn, ~p"/cron/#{cron.id}/edit")

      view
      |> form("#cron-form", cron: %{schedule_type: "interval", interval_seconds: 900})
      |> render_submit()

      assert Repo.reload!(cron).interval_seconds == 900

      view |> element("#cron-#{cron.id} button", "Disable") |> render_click()
      refute Repo.reload!(cron).enabled
      assert view |> element("#cron-#{cron.id}") |> render() =~ "Disabled"

      view |> element("#cron-#{cron.id} button", "Delete") |> render_click()
      refute Repo.get(CronJob, cron.id)
    end

    test "warns about crons whose queue is missing", %{conn: conn} do
      insert(:cron_job, name: "orphaned", queue_name: "ghost")
      {:ok, _view, html} = live(conn, ~p"/cron")
      assert html =~ "orphaned targets queue ghost, which does not exist"
      assert html =~ "Queue missing"
    end
  end

  defp assert_eventually(fun, attempts \\ 20) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)
    end
  end
end
