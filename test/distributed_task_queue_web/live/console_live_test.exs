defmodule DistributedTaskQueueWeb.ConsoleLiveTest do
  use DistributedTaskQueueWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DistributedTaskQueue.{CronJob, Job, Queue, QueueCache, Repo, Webhooks, WorkerSupervisor}

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

  describe "queues bulk" do
    test "pauses and resumes the selected queues only", %{conn: conn} do
      a = insert(:queue)
      b = insert(:queue)
      other = insert(:queue)
      Enum.each([a, b, other], &cleanup_queue(&1.name))

      {:ok, view, _html} = live(conn, ~p"/queues")
      refute has_element?(view, "#bulk-bar")

      view |> element("#select-#{a.name}") |> render_click()
      view |> element("#select-#{b.name}") |> render_click()
      assert view |> element("#bulk-bar button", "Pause") |> render_click() =~ "Paused 2 queues."

      assert Repo.reload!(a).paused
      assert Repo.reload!(b).paused
      refute Repo.reload!(other).paused
      refute has_element?(view, "#bulk-bar")

      view |> element("#select-#{a.name}") |> render_click()
      assert view |> element("#bulk-bar button", "Resume") |> render_click() =~ "Resumed 1 queue."
      refute Repo.reload!(a).paused
    end

    test "deletes the selected queues", %{conn: conn} do
      a = insert(:queue)
      keep = insert(:queue)
      Enum.each([a, keep], &cleanup_queue(&1.name))

      {:ok, view, _html} = live(conn, ~p"/queues")
      view |> element("#select-#{a.name}") |> render_click()
      assert view |> element("#bulk-bar button", "Delete") |> render_click() =~ "Deleted 1 queue."

      refute Repo.get_by(Queue, name: a.name)
      assert Repo.get_by(Queue, name: keep.name)
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

    test "the Elixir worker form still works", %{conn: conn} do
      queue = insert(:queue, name: "emails")
      cleanup_queue(queue.name)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      view |> form("#job-form", job: %{kind: "worker"}) |> render_change()

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

  describe "job detail" do
    defp webhook_job(attrs \\ []) do
      queue = insert(:queue)
      cleanup_queue(queue.name)
      DistributedTaskQueue.pause_queue(queue.name)

      insert(
        :job,
        Keyword.merge(
          [
            queue_name: queue.name,
            worker_module: DistributedTaskQueue.Workers.Webhook.module_name(),
            payload: %{
              "url" => "https://example.com/hook",
              "method" => "POST",
              "headers" => %{"x-api-key" => "s3cr3t-value", "accept" => "text/plain"},
              "body" => ~s({"order":42})
            }
          ],
          attrs
        )
      )
    end

    test "shows each delivery attempt", %{conn: conn} do
      job = webhook_job(status: "retryable")

      {:ok, _} =
        Webhooks.record_delivery(job, %{
          status_code: 503,
          duration_ms: 120,
          response_body: "<b>down</b>"
        })

      {:ok, _} = Webhooks.record_delivery(job, %{error: "connection refused", duration_ms: 3})

      {:ok, view, html} = live(conn, ~p"/jobs/#{job.id}")
      assert has_element?(view, "#delivery-1", "503 Service Unavailable")
      assert has_element?(view, "#delivery-1", "120 ms")
      assert has_element?(view, "#delivery-2", "connection refused")
      # The response is shown as text, never as markup.
      assert html =~ "&lt;b&gt;down&lt;/b&gt;"
      refute html =~ "<b>down</b>"
      assert html =~ "https://example.com/hook"
    end

    test "never shows a credential header value", %{conn: conn} do
      job = webhook_job()
      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")
      refute html =~ "s3cr3t-value"
      assert html =~ "••••"
      assert html =~ "text/plain"
    end

    test "dead-lettered webhook shows the plain reason", %{conn: conn} do
      job =
        webhook_job(
          status: "discarded",
          dead_letter: true,
          error_message: "The server answered 500 on every attempt"
        )

      {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")
      assert has_element?(view, "#job-error", "The server answered 500 on every attempt")
    end

    test "the error title tells a permanent failure from used-up retries", %{conn: conn} do
      dead = [status: "discarded", dead_letter: true, error_message: "boom", max_attempts: 5]
      permanent = webhook_job([attempts: 0] ++ dead)
      exhausted = webhook_job([attempts: 4] ++ dead)

      {:ok, _view, html} = live(conn, ~p"/jobs/#{permanent.id}")
      assert html =~ "Failed permanently — retrying would not help."
      refute html =~ "Failed on every attempt"

      {:ok, _view, html} = live(conn, ~p"/jobs/#{exhausted.id}")
      assert html =~ "Failed on every attempt"
    end

    test "a failed job can be retried and a waiting one stopped", %{conn: conn} do
      queue = insert(:queue)
      cleanup_queue(queue.name)
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      failed = insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true)

      {:ok, view, _html} = live(conn, ~p"/jobs/#{failed.id}")
      refute has_element?(view, "button", "Stop")
      assert view |> element("button", "Retry") |> render_click() =~ "will run again"
      assert %Job{status: "pending", dead_letter: false} = Repo.reload!(failed)

      # Now waiting, it offers Stop, and Retry becomes "Run now".
      assert has_element?(view, "button", "Run now")
      assert view |> element("button", "Stop") |> render_click() =~ "stopped"
      assert %Job{status: "cancelled"} = Repo.reload!(failed)
      assert render(view) =~ "Stopped"
    end

    test "the job list offers Retry and Stop per row", %{conn: conn} do
      queue = insert(:queue)
      cleanup_queue(queue.name)
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      waiting = insert(:job, queue_name: queue.name)
      done = insert(:job, queue_name: queue.name, status: "completed")

      {:ok, view, _html} = live(conn, ~p"/jobs")
      refute has_element?(view, "#job-#{done.id} button", "Stop")

      view |> element("#job-#{waiting.id} button", "Stop") |> render_click()
      assert Repo.reload!(waiting).status == "cancelled"

      view |> element("#job-#{done.id} button", "Retry") |> render_click()
      assert Repo.reload!(done).status == "pending"
    end

    test "bulk actions apply to the selected jobs only", %{conn: conn} do
      queue = insert(:queue)
      cleanup_queue(queue.name)
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      a = insert(:job, queue_name: queue.name)
      b = insert(:job, queue_name: queue.name, status: "completed")
      untouched = insert(:job, queue_name: queue.name)

      {:ok, view, _html} = live(conn, ~p"/jobs?queue=#{queue.name}")
      refute has_element?(view, "#bulk-bar")

      view |> element("#select-#{a.id}") |> render_click()
      view |> element("#select-#{b.id}") |> render_click()
      assert view |> element("#bulk-bar") |> render() =~ "2 selected"

      html = view |> element("#bulk-bar button", "Stop") |> render_click()
      assert html =~ "Stopped 1 job. Skipped 1: already finished."

      assert Repo.reload!(a).status == "cancelled"
      assert Repo.reload!(b).status == "completed"
      assert Repo.reload!(untouched).status == "pending"
      refute has_element?(view, "#bulk-bar")
    end

    test "select-all picks every job on the page and toggles off", %{conn: conn} do
      queue = insert(:queue)
      cleanup_queue(queue.name)
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      insert(:job, queue_name: queue.name, status: "completed")
      insert(:job, queue_name: queue.name, status: "completed")

      {:ok, view, _html} = live(conn, ~p"/jobs?queue=#{queue.name}")
      view |> element("#select-page") |> render_click()
      assert view |> element("#bulk-bar") |> render() =~ "2 selected"

      assert view |> element("#bulk-bar button", "Retry") |> render_click() =~ "Retried 2 jobs."

      view |> element("#select-page") |> render_click()
      view |> element("#select-page") |> render_click()
      refute has_element?(view, "#bulk-bar")
    end

    test "non-webhook jobs keep the raw payload panel", %{conn: conn} do
      job = insert(:job)
      {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")
      assert has_element?(view, "#job-payload")
      refute has_element?(view, "#deliveries")
    end
  end

  describe "webhook jobs" do
    setup do
      queue = insert(:queue, name: "webhooks")
      cleanup_queue(queue.name)
      :ok
    end

    test "creating a webhook job from the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs/new")
      view |> element("button", "Add a header") |> render_click()

      view
      |> form("#job-form",
        job: %{
          url: "http://127.0.0.1:9/hook",
          method: "PUT",
          body: ~s({"order": 42}),
          headers: %{"0" => %{key: "X-Api-Key", value: "abc"}}
        }
      )
      |> render_submit()

      assert [job] = Repo.all(Job)
      assert job.worker_module == DistributedTaskQueue.Workers.Webhook.module_name()
      assert job.queue_name == "webhooks"
      assert job.max_attempts == 5
      assert job.payload["url"] == "http://127.0.0.1:9/hook"
      assert job.payload["method"] == "PUT"
      assert job.payload["headers"]["x-api-key"] == "abc"
      assert job.payload["body"] == ~s({"order":42})
      assert render(view) =~ "Job ##{job.id} enqueued on webhooks"
    end

    test "inline error for a bad URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      html =
        view
        |> form("#job-form", job: %{url: "ftp://example.com/x"})
        |> render_submit()

      assert html =~ "must be an http or https URL"
      assert Repo.all(Job) == []
    end

    test "demo_receivers mode shows a receiver picker, not a URL field", %{conn: conn} do
      original = Application.get_env(:distributed_task_queue, :webhooks, [])

      Application.put_env(
        :distributed_task_queue,
        :webhooks,
        Keyword.put(original, :targets, :demo_receivers)
      )

      on_exit(fn -> Application.put_env(:distributed_task_queue, :webhooks, original) end)

      {:ok, view, html} = live(conn, ~p"/jobs/new")

      assert html =~ "Payments"
      assert has_element?(view, "select#job_url")
      refute has_element?(view, "input#job_url")

      url = DistributedTaskQueue.Webhooks.Target.demo_receiver_url("email")
      view |> form("#job-form", job: %{url: url}) |> render_submit()

      assert [job] = Repo.all(Job)
      assert job.payload["url"] == url
    end

    test "run in 10 minutes sets scheduled_at", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs/new")
      view |> form("#job-form", job: %{when: "in"}) |> render_change()

      view
      |> form("#job-form", job: %{url: "http://127.0.0.1:9/hook", in_minutes: "10"})
      |> render_submit()

      assert [job] = Repo.all(Job)
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now())
      assert diff in 590..610
    end

    test "run at a date and time is read as UTC", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs/new")
      view |> form("#job-form", job: %{when: "at"}) |> render_change()

      view
      |> form("#job-form", job: %{url: "http://127.0.0.1:9/hook", run_at: "2099-11-05T09:30"})
      |> render_submit()

      assert [job] = Repo.all(Job)
      assert DateTime.to_iso8601(job.scheduled_at) == "2099-11-05T09:30:00Z"
    end

    test "headers can be added and removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs/new")
      view |> element("button", "Add a header") |> render_click()
      view |> element("button", "Add a header") |> render_click()
      assert has_element?(view, "#header-row-1")

      view |> element("#header-row-0 button", "Remove") |> render_click()
      assert has_element?(view, "#header-row-0")
      refute has_element?(view, "#header-row-1")
    end
  end

  describe "dead letter" do
    test "filters by queue and requeues one job", %{conn: conn} do
      a = insert(:queue, name: "a")
      cleanup_queue(a.name)
      # Paused, so the requeued job is not run before we look at it.
      {:ok, _} = DistributedTaskQueue.pause_queue(a.name)
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

  describe "dead letter bulk" do
    test "requeues and deletes the selected jobs", %{conn: conn} do
      queue = insert(:queue)
      cleanup_queue(queue.name)
      {:ok, _} = DistributedTaskQueue.pause_queue(queue.name)
      dead = fn -> insert(:job, queue_name: queue.name, status: "discarded", dead_letter: true) end
      [a, b, c] = [dead.(), dead.(), dead.()]

      {:ok, view, _html} = live(conn, ~p"/dead-letter?queue=#{queue.name}")
      view |> element("#select-#{a.id}") |> render_click()
      view |> element("#select-#{b.id}") |> render_click()

      assert view |> element("#bulk-bar button", "Requeue") |> render_click() =~
               "Requeued 2 jobs."

      assert %Job{status: "pending", dead_letter: false} = Repo.reload!(a)
      assert %Job{status: "pending", dead_letter: false} = Repo.reload!(b)
      assert Repo.reload!(c).dead_letter

      view |> element("#select-page") |> render_click()
      assert view |> element("#bulk-bar button", "Delete") |> render_click() =~ "Deleted 1 job."
      assert Repo.reload!(c).status == "deleted"
    end
  end

  describe "cron bulk" do
    test "disables, enables and deletes the selected cron jobs", %{conn: conn} do
      a = insert(:cron_job)
      b = insert(:cron_job, enabled: false)
      keep = insert(:cron_job)

      {:ok, view, _html} = live(conn, ~p"/cron")
      view |> element("#select-#{a.id}") |> render_click()
      view |> element("#select-#{b.id}") |> render_click()

      assert view |> element("#bulk-bar button", "Disable") |> render_click() =~
               "Disabled 1 cron job. Skipped 1: already disabled."

      refute Repo.reload!(a).enabled
      assert Repo.reload!(keep).enabled

      view |> element("#select-#{a.id}") |> render_click()
      view |> element("#select-#{b.id}") |> render_click()

      assert view |> element("#bulk-bar button", "Enable") |> render_click() =~
               "Enabled 2 cron jobs."

      assert Repo.reload!(a).enabled and Repo.reload!(b).enabled

      view |> element("#select-#{a.id}") |> render_click()

      assert view |> element("#bulk-bar button", "Delete") |> render_click() =~
               "Deleted 1 cron job."

      refute Repo.get(CronJob, a.id)
      assert Repo.get(CronJob, keep.id)
    end
  end

  describe "cron" do
    test "creates an interval cron job", %{conn: conn} do
      insert(:queue, name: "emails")
      {:ok, view, _html} = live(conn, ~p"/cron/new")

      view
      |> form("#cron-form", cron: %{kind: "worker", schedule_type: "interval"})
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
      view |> form("#cron-form", cron: %{kind: "worker"}) |> render_change()

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

  describe "webhook crons" do
    alias DistributedTaskQueue.Webhooks
    alias DistributedTaskQueue.Webhooks.Request
    alias DistributedTaskQueue.Workers.Webhook, as: WebhookWorker

    defp webhook_cron(name, webhook) do
      attrs = Webhooks.cron_attrs(%{"webhook" => webhook})

      {:ok, cron} =
        DistributedTaskQueue.create_cron_job(
          Map.merge(attrs, %{"name" => name, "queue_name" => "webhooks", "interval_seconds" => 60})
        )

      cron
    end

    setup do
      insert(:queue, name: "webhooks")
      :ok
    end

    test "creating a webhook cron from the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cron/new")
      view |> element("button", "Add a header") |> render_click()

      view
      |> form("#cron-form",
        cron: %{
          name: "nightly-ping",
          schedule_type: "cron",
          cron_expression: "0 2 * * *",
          timezone: "Africa/Nairobi",
          webhook: %{
            url: "http://127.0.0.1:9/hook",
            method: "PUT",
            body: ~s({"order": 42}),
            headers: %{"0" => %{key: "X-Api-Key", value: "abc"}}
          }
        }
      )
      |> render_submit()

      cron = Repo.get_by!(CronJob, name: "nightly-ping")
      assert cron.worker_module == WebhookWorker.module_name()
      assert cron.queue_name == "webhooks"
      assert cron.cron_expression == "0 2 * * *"
      assert cron.payload["url"] == "http://127.0.0.1:9/hook"
      assert cron.payload["method"] == "PUT"
      assert cron.payload["headers"]["x-api-key"] == "abc"
      assert cron.payload["body"] == ~s({"order":42})
      # Webhooks default to 5 attempts, from the console as from the API.
      assert cron.max_attempts == 5
      assert render(view) =~ "Cron job nightly-ping saved"
    end

    test "a bad URL is reported inline and nothing is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cron/new")

      html =
        view
        |> form("#cron-form",
          cron: %{
            name: "bad-url",
            schedule_type: "cron",
            cron_expression: "* * * * *",
            webhook: %{url: "ftp://example.com/x"}
          }
        )
        |> render_submit()

      assert html =~ "must be an http or https URL"
      refute Repo.get_by(CronJob, name: "bad-url")
    end

    test "the cron list and overview show the plain-English schedule", %{conn: conn} do
      queue = insert(:queue)

      insert(:cron_job,
        name: "morning",
        queue_name: queue.name,
        interval_seconds: nil,
        cron_expression: "0 9 * * 1",
        timezone: "Africa/Nairobi"
      )

      insert(:cron_job, name: "frequent", queue_name: queue.name, interval_seconds: 30)

      {:ok, _view, html} = live(conn, ~p"/cron")
      assert html =~ "Every Monday at 09:00 (Africa/Nairobi)"
      assert html =~ "Every 30 seconds"
      # The raw expression stays available for developers.
      assert html =~ ~s(title="0 9 * * 1")

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Every Monday at 09:00 (Africa/Nairobi)"
      assert html =~ "Every 30 seconds"
    end

    test "editing a webhook cron without touching a redacted header keeps the secret",
         %{conn: conn} do
      cron =
        webhook_cron("secured", %{
          "url" => "http://127.0.0.1:9/hook",
          "headers" => %{"authorization" => "Bearer s3cret", "x-note" => "hello"},
          "timeout_ms" => 7000
        })

      stored = cron.payload["headers"]

      {:ok, view, html} = live(conn, ~p"/cron/#{cron.id}/edit")
      refute html =~ "s3cret"
      assert html =~ Request.masked()
      assert html =~ "hello"

      view |> form("#cron-form", cron: %{max_attempts: 4}) |> render_submit()

      reloaded = Repo.reload!(cron)
      assert reloaded.max_attempts == 4
      assert reloaded.payload["headers"] == stored
      assert reloaded.payload["headers"]["authorization"] == "Bearer s3cret"
      assert reloaded.payload["timeout_ms"] == 7000
    end

    test "overwriting a redacted header replaces the secret", %{conn: conn} do
      cron =
        webhook_cron("rotate", %{
          "url" => "http://127.0.0.1:9/hook",
          "headers" => %{"authorization" => "Bearer old"}
        })

      {:ok, view, _html} = live(conn, ~p"/cron/#{cron.id}/edit")

      view
      |> form("#cron-form",
        cron: %{webhook: %{headers: %{"0" => %{key: "authorization", value: "Bearer new"}}}}
      )
      |> render_submit()

      assert Repo.reload!(cron).payload["headers"]["authorization"] == "Bearer new"
    end

    test "an existing worker cron opens as a worker form", %{conn: conn} do
      cron = insert(:cron_job, name: "legacy")
      {:ok, view, _html} = live(conn, ~p"/cron/#{cron.id}/edit")
      assert has_element?(view, "input[name='cron[worker_module]']")
      refute has_element?(view, "input[name='cron[webhook][url]']")
    end
  end

  describe "demo" do
    alias DistributedTaskQueue.Demo.Receivers

    setup do
      Receivers.ensure_all()
      Receivers.set_online("warehouse", true)

      for key <- [:demo_mode, :demo_api_key] do
        old = Application.fetch_env(:distributed_task_queue, key)

        on_exit(fn ->
          case old do
            {:ok, v} -> Application.put_env(:distributed_task_queue, key, v)
            :error -> Application.delete_env(:distributed_task_queue, key)
          end
        end)
      end

      :ok
    end

    test "demo controls toggle a receiver offline and back", %{conn: conn} do
      Application.put_env(:distributed_task_queue, :demo_mode, true)
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#receiver-warehouse button") |> render_click()
      refute Receivers.online?("warehouse")
      assert render(view) =~ ~r/back online at \d\d:\d\d UTC/

      view |> element("#receiver-warehouse button") |> render_click()
      assert Receivers.online?("warehouse")
    end

    test "an unknown receiver name is ignored", %{conn: conn} do
      Application.put_env(:distributed_task_queue, :demo_mode, true)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_receiver", %{"name" => "nope"})
      assert render(view) =~ "Overview"
    end

    test "demo controls are hidden outside demo mode", %{conn: conn} do
      Application.put_env(:distributed_task_queue, :demo_mode, false)
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "Demo controls"
      refute has_element?(view, "#receiver-warehouse")
    end

    test "intro shows the demo key and curl example when configured", %{conn: conn} do
      Application.put_env(:distributed_task_queue, :demo_mode, true)
      Application.put_env(:distributed_task_queue, :demo_api_key, "key-abc-123")
      {:ok, view, _html} = live(conn, ~p"/")
      intro = view |> element("#demo-intro") |> render()
      assert intro =~ "key-abc-123"
      assert intro =~ "curl"
      assert intro =~ "/demo/receivers/warehouse"
    end

    test "intro omits the curl example without a key", %{conn: conn} do
      Application.put_env(:distributed_task_queue, :demo_api_key, nil)
      {:ok, view, _html} = live(conn, ~p"/")
      refute view |> element("#demo-intro") |> render() =~ "curl"
    end

    test "status badges explain themselves", %{conn: conn} do
      at = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)

      job =
        insert(:job, status: "retryable", attempts: 1, error_message: "boom", next_retry_at: at)

      {:ok, view, _html} = live(conn, ~p"/")
      assert view |> element("#failure-#{job.id}") |> render() =~ "will try again at"
    end

    test "status hints cover every state" do
      import DistributedTaskQueueWeb.ConsoleComponents, only: [status_hint: 1]
      assert status_hint(%{dead_letter: true, attempts: 1}) == "Gave up after 1 try"
      assert status_hint(%{dead_letter: true, attempts: 3}) == "Gave up after 3 tries"
      assert status_hint(%{dead_letter: false, status: "pending"}) == "Waiting its turn"
      assert status_hint(%{dead_letter: false, status: "started"}) == "Running now"
      assert status_hint(%{dead_letter: false, status: "completed"}) == "Done"
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
