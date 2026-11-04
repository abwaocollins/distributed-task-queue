defmodule DistributedTaskQueue.Workers.WebhookTest do
  # Changes Application env, so it cannot run alongside other tests.
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{HttpReceiver, Job, Repo, Webhooks, Worker}
  alias DistributedTaskQueue.Webhooks.Signature
  alias DistributedTaskQueue.Workers.Webhook

  @secret "test-signing-secret"

  setup do
    original = Application.get_env(:distributed_task_queue, :webhooks)
    on_exit(fn -> Application.put_env(:distributed_task_queue, :webhooks, original) end)
    :ok
  end

  defp put_webhooks_config(changes) do
    current = Application.get_env(:distributed_task_queue, :webhooks, [])
    Application.put_env(:distributed_task_queue, :webhooks, Keyword.merge(current, changes))
  end

  defp respond(status, body \\ "") do
    fn conn -> Plug.Conn.send_resp(conn, status, body) end
  end

  defp webhook_job(payload) do
    insert(:job,
      worker_module: Webhook.module_name(),
      payload: Map.put_new(payload, "timeout_ms", 2_000),
      max_attempts: 3
    )
  end

  defp run(job) do
    Worker.run_job(job)
    Repo.get!(Job, job.id)
  end

  test "module_name/0 is the string a job stores" do
    assert Webhook.module_name() == "DistributedTaskQueue.Workers.Webhook"
  end

  test "2xx completes and records delivery 1 with status and body" do
    base = HttpReceiver.start(respond(200, "thanks"))
    job = webhook_job(%{"url" => base <> "/hook", "body" => %{"a" => 1}})

    assert run(job).status == "completed"

    assert [delivery] = Webhooks.list_deliveries(job.id)
    assert delivery.number == 1
    assert delivery.status_code == 200
    assert delivery.response_body == "thanks"
    assert delivery.method == "POST"
    assert delivery.url == base <> "/hook"
    assert is_integer(delivery.duration_ms)
    assert delivery.error == nil

    assert_received {:received, "POST", "/hook", _headers, ~s({"a":1})}
  end

  for status <- [503, 429, 408] do
    test "#{status} is retryable" do
      base = HttpReceiver.start(respond(unquote(status)))
      job = webhook_job(%{"url" => base})

      job = run(job)
      assert job.status == "retryable"
      assert job.error_message =~ "#{unquote(status)}"

      assert [%{status_code: unquote(status)}] = Webhooks.list_deliveries(job.id)
    end
  end

  test "404 dead-letters on the first attempt with a plain reason" do
    base = HttpReceiver.start(respond(404, "nope"))
    job = webhook_job(%{"url" => base})

    job = run(job)
    assert job.status == "discarded"
    assert job.attempts == 0
    assert job.error_message =~ "rejected it (404"

    assert [%{status_code: 404, response_body: "nope"}] = Webhooks.list_deliveries(job.id)
  end

  test "302 dead-letters and says redirects are not followed" do
    landing = HttpReceiver.start(respond(200))

    base =
      HttpReceiver.start(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", landing <> "/landing")
        |> Plug.Conn.send_resp(302, "")
      end)

    job = webhook_job(%{"url" => base <> "/start"})

    job = run(job)
    assert job.status == "discarded"
    assert job.error_message =~ "302"
    assert job.error_message =~ "redirects are not followed"

    assert_received {:received, _, "/start", _, _}
    refute_receive {:received, _, "/landing", _, _}, 100
    assert [%{status_code: 302}] = Webhooks.list_deliveries(job.id)
  end

  test "connection refused is retryable" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    # Windows retries a refused connect for about 2 s before giving up, so
    # leave room for that inside timeout_ms.
    job = webhook_job(%{"url" => "http://127.0.0.1:#{port}/", "timeout_ms" => 5_000})

    job = run(job)
    assert job.status == "retryable"
    assert job.error_message =~ "refused"

    assert [%{status_code: nil, error: error}] = Webhooks.list_deliveries(job.id)
    assert error =~ "refused"
  end

  test "an unresolvable host is retryable and sends nothing" do
    job = webhook_job(%{"url" => "http://no-such-host.invalid/hook"})

    job = run(job)
    assert job.status == "retryable"
    assert job.error_message =~ "couldn't find that address"
    assert Webhooks.list_deliveries(job.id) == []
  end

  test "an unexpected status dead-letters without saying it was rejected" do
    # Bandit refuses to send a status outside 1xx-5xx, so answer by hand.
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false, reuseaddr: true)
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(socket, 0)
      :ok = :gen_tcp.send(socket, "HTTP/1.1 600 Odd
content-length: 0

")
      :gen_tcp.close(socket)
    end)

    job = webhook_job(%{"url" => "http://127.0.0.1:#{port}/"})

    job = run(job)
    assert job.status == "discarded"
    assert job.error_message =~ "unexpected response (600"
    refute job.error_message =~ "rejected"
  end

  # 10.255.255.1 is normally unroutable, so the connect hangs; where the
  # network refuses it outright instead, the job still fails fast.
  test "a host that never accepts the connection fails within timeout_ms" do
    job = webhook_job(%{"url" => "http://10.255.255.1/", "timeout_ms" => 300})

    {elapsed_us, job} = :timer.tc(fn -> run(job) end)

    assert elapsed_us < 1_000_000
    assert job.status == "retryable"
    assert [%{status_code: nil, error: error}] = Webhooks.list_deliveries(job.id)
    assert error =~ "No response within 300ms" or error =~ "Could not reach"
  end

  test "a receiver that never answers times out" do
    base =
      HttpReceiver.start(fn conn ->
        Process.sleep(2_000)
        Plug.Conn.send_resp(conn, 200, "")
      end)

    job = webhook_job(%{"url" => base, "timeout_ms" => 200})

    {elapsed_us, job} = :timer.tc(fn -> run(job) end)

    assert elapsed_us < 1_000_000
    assert job.status == "retryable"
    assert job.error_message =~ "No response within 200ms"

    assert [%{status_code: nil, error: error}] = Webhooks.list_deliveries(job.id)
    assert error =~ "No response within"
  end

  test "sends service headers the caller cannot override" do
    put_webhooks_config(secret: @secret)
    base = HttpReceiver.start(respond(204))

    job =
      webhook_job(%{
        "url" => base,
        "body" => "hello",
        "headers" => %{
          "X-DTQ-Signature" => "forged",
          "x-dtq-job-id" => "999",
          "User-Agent" => "evil",
          "X-Custom" => "kept"
        }
      })

    assert run(job).status == "completed"

    assert_received {:received, "POST", "/", headers, "hello"}

    # A duplicated header would mean the caller's copy survived.
    for name <- ~w(user-agent x-dtq-job-id x-dtq-attempt x-dtq-signature) do
      assert length(for {^name, _} <- headers, do: name) == 1, "expected one #{name}"
    end

    headers = Map.new(headers)
    assert headers["x-dtq-job-id"] == to_string(job.id)
    assert headers["x-dtq-attempt"] == "1"
    assert headers["x-custom"] == "kept"
    assert String.starts_with?(headers["user-agent"], "dtq-webhook/")
    assert Signature.valid?(headers["x-dtq-signature"], "hello", @secret)
  end

  test "signs the empty string when there is no body" do
    put_webhooks_config(secret: @secret)
    base = HttpReceiver.start(respond(200))
    job = webhook_job(%{"url" => base, "method" => "GET"})

    assert run(job).status == "completed"

    assert_received {:received, "GET", "/", headers, ""}
    assert Signature.valid?(Map.new(headers)["x-dtq-signature"], "", @secret)
  end

  test "omits the signature when no secret is configured" do
    put_webhooks_config(secret: nil)
    base = HttpReceiver.start(respond(200))
    job = webhook_job(%{"url" => base})

    assert run(job).status == "completed"

    assert_received {:received, "POST", "/", headers, _}
    refute List.keymember?(headers, "x-dtq-signature", 0)
  end

  test "blocked target dead-letters without sending" do
    put_webhooks_config(allow_private_targets: false)
    base = HttpReceiver.start(respond(200))
    job = webhook_job(%{"url" => base})

    job = run(job)
    assert job.status == "discarded"
    assert job.error_message =~ "private network"

    refute_receive {:received, _, _, _, _}, 100
    assert Webhooks.list_deliveries(job.id) == []
  end

  test "an invalid payload dead-letters without sending" do
    job = webhook_job(%{"url" => "not a url"})

    job = run(job)
    assert job.status == "discarded"
    assert job.error_message =~ "url"
    assert Webhooks.list_deliveries(job.id) == []
  end

  test "stores a huge response truncated" do
    base = HttpReceiver.start(respond(200, String.duplicate("x", 100_000)))
    job = webhook_job(%{"url" => base})

    assert run(job).status == "completed"

    assert [delivery] = Webhooks.list_deliveries(job.id)
    assert delivery.status_code == 200
    assert byte_size(delivery.response_body) <= 2048
    assert String.starts_with?(delivery.response_body, "xxxx")
  end
end
