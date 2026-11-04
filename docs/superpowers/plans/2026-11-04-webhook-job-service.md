# Webhook Job Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in "call this URL" job type with signed, retried, recorded deliveries, a way to create webhooks from the API and console without code, and a recruiter-readable demo (Acme Store) whose receivers a visitor can switch offline.

**Architecture:** Webhook jobs are ordinary `jobs` rows whose `worker_module` is `DistributedTaskQueue.Workers.Webhook`, so they ride the existing claim / retry / dead-letter / reaper path. A small `DistributedTaskQueue.Webhooks` namespace owns request validation, target safety, signing and delivery history. The demo is built from in-app receiver routes plus DB-backed switches.

**Tech Stack:** Elixir 1.18 / OTP 25+, Phoenix 1.7, LiveView 1.1, Ecto + Postgres, Finch (existing, named `DistributedTaskQueue.Finch`), Bandit (existing — also used in tests as a real HTTP receiver).

**Spec:** `docs/superpowers/specs/2026-11-04-webhook-job-service-design.md`

## Global Constraints

- Existing jobs with an Elixir `worker_module` keep working unchanged, from the API and the console. The full suite (`mix test`) stays green after every task.
- Nothing in the console or API may cause arbitrary code execution; `Worker.resolve/1` remains the only route to Elixir code.
- Webhook methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. Schemes: `http`, `https`. Default method `POST`.
- `timeout_ms` default 15 000, capped at 60 000.
- Webhook `max_attempts` default **5**; `webhooks` queue concurrency **10**, created at boot if missing, never overwritten.
- Backoff is the existing `min(15 × 2^attempts, 3600)` s. `Retry-After` is ignored. Redirects are never followed.
- Response body stored: first **2 KB** only.
- Headers always sent, not overridable by the caller: `user-agent: dtq-webhook/<version>`, `x-dtq-job-id`, `x-dtq-attempt` (1-based), `x-dtq-signature: t=<unix>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">` keyed by `DTQ_WEBHOOK_SECRET` (omitted when no secret is configured).
- Redacted on display (console + API), shown as `••••`: `authorization`, `cookie`, `proxy-authorization`, and any header whose lowercased name contains `token`, `secret`, `key` or `signature`.
- Target modes: `config :distributed_task_queue, :webhooks, targets: :any | :demo_receivers` (default `:any`). In `:demo_receivers`, cron jobs have a **10-second** minimum interval.
- Private-address blocking: `config :distributed_task_queue, :webhooks, allow_private_targets: true` in dev and test, `false` in prod.
- Demo receiver switches auto-reset to Online after **5 minutes**. The Acme Store places an order every **~10 s**; the "Daily sales report" cron runs every minute in demo mode.
- Prod env vars: `DTQ_WEBHOOK_SECRET` (required in prod; boot raises without it), `DTQ_WEBHOOK_TARGETS` (`any` | `demo`), `DTQ_DEMO_API_KEY` (accepted alongside `DTQ_API_KEYS`).
- Follow existing code style: plain-English `@moduledoc`/comments explaining *why*, `mix format` on new files only, `mix compile --warnings-as-errors` clean.

## Review Focus

1. **A receiver that accepts the connection but never answers.** Expect a failed attempt with a timeout error after `timeout_ms`, the slot freed, and a retry scheduled — not a hung worker. → test in Task 5.
2. **A huge or non-UTF-8 response body.** Expect the delivery row saved with at most 2 KB of valid UTF-8 (invalid bytes replaced), never an Ecto/Postgres error that loses the delivery record. → test in Task 5.
3. **Private targets in disguise:** `http://localhost/`, `http://[::1]/`, `http://127.1/`, `http://2130706433/`, `http://169.254.169.254/latest/meta-data`, a hostname that resolves to `10.x`. Expect all refused when private targets are disallowed. → tests in Task 3.
4. **A caller trying to spoof service headers** (`x-dtq-signature`, `x-dtq-job-id`, `User-Agent` in any case). Expect the service's values to win. → test in Task 5.
5. **Saving an edit form without touching a redacted header.** Expect the stored secret kept, not replaced with `••••`. → tests in Tasks 7 and 8.

---

## File map

| Path | Responsibility |
|---|---|
| `lib/distributed_task_queue/worker.ex` (modify) | optional `perform_job/1` callback; `{:discard, reason}` outcome |
| `lib/distributed_task_queue/webhooks.ex` | context: enqueue, deliveries, queue bootstrap, config readers |
| `lib/distributed_task_queue/webhooks/request.ex` | payload validation/normalisation, redaction, masked-value merge |
| `lib/distributed_task_queue/webhooks/target.ex` | URL safety: private-address blocking + target mode |
| `lib/distributed_task_queue/webhooks/signature.ex` | sign / verify |
| `lib/distributed_task_queue/webhooks/delivery.ex` | `webhook_deliveries` schema |
| `lib/distributed_task_queue/workers/webhook.ex` | the worker: send, classify, record |
| `lib/distributed_task_queue_web/controllers/webhook_controller.ex` | `POST /api/webhooks` |
| `lib/distributed_task_queue_web/schedule_text.ex` | plain-English schedule |
| `lib/distributed_task_queue_web/live/webhook_fields.ex` | shared form component for webhook fields |
| `lib/distributed_task_queue/demo/receivers.ex` + `demo/receiver.ex` | switch state |
| `lib/distributed_task_queue_web/controllers/demo_receiver_controller.ex` | receiver endpoints |
| `lib/distributed_task_queue/demo/order_worker.ex` | Acme Store order fan-out |
| `lib/distributed_task_queue_web/live/demo_controls.ex` | demo controls component |
| `test/support/http_receiver.ex` | Bandit-backed test receiver |

---

### Task 1: Worker contract — job context and permanent failure

**Files:**
- Modify: `lib/distributed_task_queue/worker.ex`
- Test: `test/distributed_task_queue/worker_test.exs`

**Interfaces:**
- Produces:
  - `@callback perform_job(job :: DistributedTaskQueue.Job.t()) :: :ok | {:error, term} | {:discard, term}` (optional). `dispatch/4` calls `perform_job/1` when the module exports it, else `perform/1` with the payload.
  - Both callbacks may return `{:discard, reason}`, which goes straight to `"discarded"` (dead letter) whatever `attempts` is, emitting `[:dtq, :job, :failed]` as today.

- [ ] **Step 1: Write the failing tests** — in `worker_test.exs`, using test-only worker modules defined at the top of the file:
  - `"perform_job/1 receives the whole job"`: the worker sends `{:got, job.id, job.attempts}` to a pid in the payload; assert it is received.
  - `"{:discard, reason} dead-letters on the first attempt"`: job with `attempts: 0, max_attempts: 5`; after `Worker.run_job/1`, `status == "discarded"`, `dead_letter == true`, `error_message == reason`.
  - `"perform/1 workers are unaffected"`: the existing EmailWorker job still completes.
- [ ] **Step 2: Run** `mix test test/distributed_task_queue/worker_test.exs` — Expected: the two new tests FAIL.
- [ ] **Step 3: Implement** in `worker.ex`: add the optional callback, choose the callback with `function_exported?(module, :perform_job, 1)`, and route `{:discard, reason}` through `fail/4` with a forced `"discarded"` status. Keep `handle_failure/2` as the only place that decides retryable vs discarded, with a `force_discard?` flag.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(worker): optional perform_job/1 and {:discard, reason}`

---

### Task 2: Webhook request validation and redaction

**Files:**
- Create: `lib/distributed_task_queue/webhooks/request.ex`
- Test: `test/distributed_task_queue/webhooks/request_test.exs`

**Interfaces:**
- Produces:
  - `Request.normalize(map) :: {:ok, map} | {:error, [{atom, String.t()}]}` — the returned map has string keys `"url"`, `"method"` (upcased), `"headers"` (lowercased keys, string values), `"body"` (string, or nil), `"timeout_ms"` (int).
    - A map or list `body` is JSON-encoded. When it is, `content-type: application/json` is added unless the caller supplied one.
    - Errors use the field atoms `:url`, `:method`, `:headers`, `:body`, `:timeout_ms`.
    - No network access. Target safety is Task 3.
  - `Request.redact_headers(map) :: map` — per Global Constraints.
  - `Request.merge_masked(new_headers :: map, stored_headers :: map) :: map` — any value equal to `"••••"` takes the stored value for that header name.
  - `@masked "••••"` exposed as `Request.masked/0`.

- [ ] **Step 1: Write the failing tests:**
  - `"defaults method to POST and timeout to 15_000"`.
  - `"caps timeout_ms at 60_000"`.
  - `"rejects a non-http(s) url"`, for each of `"ftp://x"`, `"javascript:alert(1)"`, `"not a url"` and `""`: assert `{:error, [{:url, _} | _]}`.
  - `"rejects unknown methods"`: `"TRACE"` gives `{:error, [{:method, _}]}`.
  - `"rejects non-string header values"`: `%{"x-n" => 1}` gives `{:error, [{:headers, _}]}`.
  - `"JSON-encodes a map body and sets content-type"`.
  - `"keeps a caller content-type"`.
  - `"redacts credential-like headers"`: `authorization`, `X-Api-Key`, `x-auth-token`, `cookie` and `my-secret` are masked; `accept` is not.
  - `"merge_masked keeps the stored secret"`: `merge_masked(%{"authorization" => "••••", "accept" => "b"}, %{"authorization" => "Bearer real", "accept" => "a"})` returns `%{"authorization" => "Bearer real", "accept" => "b"}`. (Review Focus 5.)
- [ ] **Step 2: Run** `mix test test/distributed_task_queue/webhooks/request_test.exs` — Expected: FAIL (module missing).
- [ ] **Step 3: Implement** `request.ex`. Parse with `URI.new/1`; require a scheme in `~w(http https)` and a non-empty host.
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(webhooks): request validation and header redaction`

---

### Task 3: Target safety (private addresses + target mode)

**Files:**
- Create: `lib/distributed_task_queue/webhooks/target.ex`
- Modify: `config/config.exs`, `config/dev.exs`, `config/test.exs`
- Test: `test/distributed_task_queue/webhooks/target_test.exs`

**Interfaces:**
- Produces:
  - `Target.check(url :: String.t(), opts \\ []) :: :ok | {:error, :private_address | :unresolvable | :not_a_demo_receiver}`
    - `opts`: `:targets` (`:any | :demo_receivers`) and `:allow_private` (boolean), each defaulting to the config.
    - `:demo_receivers` accepts exactly `demo_receiver_url(name)` for a known receiver, and nothing else.
  - `Target.demo_receiver_url(name :: String.t()) :: String.t()` = `DistributedTaskQueueWeb.Endpoint.url() <> "/demo/receivers/" <> name`.
  - `Target.demo_receiver_names() :: [String.t()]` = `["payments", "email", "warehouse"]`.
  - `Target.reason_text(atom) :: String.t()` — the plain-English error used by the API, the console and the worker.
- Config (all environments get keys): `config :distributed_task_queue, :webhooks, targets: :any, allow_private_targets: false` in `config.exs`; `allow_private_targets: true` in `dev.exs` and `test.exs`.

- [ ] **Step 1: Write the failing tests**, passing `allow_private: false` explicitly:
  - `"refuses loopback, private, link-local and metadata addresses"`. Loop over `http://localhost/`, `http://[::1]/`, `http://127.1/`, `http://2130706433/`, `http://10.0.0.5/`, `http://192.168.1.1/`, `http://169.254.169.254/latest/meta-data`, `http://[fc00::1]/` and `http://0.0.0.0/`; each must return `{:error, :private_address}`. (Review Focus 3.)
  - `"accepts a public address"`: `http://93.184.216.34/` returns `:ok`, with no DNS involved.
  - `"refuses an unresolvable host"`: `http://does-not-exist.invalid/` returns `{:error, :unresolvable}`.
  - `"allow_private: true lets localhost through"`.
  - `"demo_receivers mode accepts only receiver URLs"`:
    - `demo_receiver_url("warehouse")` → `:ok`.
    - `demo_receiver_url("nope")`, `"https://example.com/"`, and `demo_receiver_url("warehouse") <> "/../x"` → `{:error, :not_a_demo_receiver}`.
- [ ] **Step 2: Run** `mix test test/distributed_task_queue/webhooks/target_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement** `target.ex`.
  - Resolve with `:inet.getaddrs/2` for both `:inet` and `:inet6`. This also parses IP literals and the short or decimal IPv4 forms.
  - Refuse if **any** resolved address is in a blocked range. Blocked IPv4: `0/8`, `10/8`, `100.64/10`, `127/8`, `169.254/16`, `172.16/12`, `192.168/16`. Blocked IPv6: `::`, `::1`, `fc00::/7`, `fe80::/10`, and IPv4-mapped forms of the IPv4 ranges.
  - In `:demo_receivers` mode, compare the normalised URL string to the known receiver URLs; don't do prefix matching.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(webhooks): target safety checks and target modes`

---

### Task 4: Signing and delivery history

**Files:**
- Create: `lib/distributed_task_queue/webhooks/signature.ex`, `lib/distributed_task_queue/webhooks/delivery.ex`, `lib/distributed_task_queue/webhooks.ex`, `priv/repo/migrations/20261104000001_create_webhook_deliveries.exs`
- Test: `test/distributed_task_queue/webhooks/signature_test.exs`, `test/distributed_task_queue/webhooks_test.exs`

**Interfaces:**
- Produces:
  - `Signature.header(body :: binary, secret :: binary, unix :: integer) :: String.t()` → `"t=<unix>,v1=<hex>"`. Lowercase hex, HMAC-SHA256 over `"#{unix}.#{body}"`.
  - `Signature.valid?(header, body, secret, max_age_s \\ 300) :: boolean`.
  - Migration `webhook_deliveries`:
    - `job_id` (references `jobs`, `on_delete: :delete_all`, not null)
    - `number` (int, not null), `method`, `url`
    - `status_code` (int, null), `duration_ms` (int), `response_body` (text, null), `error` (text, null)
    - `inserted_at` (`utc_datetime`); index on `[:job_id, :number]` unique.
  - `Webhooks.record_delivery(job :: Job.t(), attrs :: map) :: {:ok, Delivery.t()}` — assigns `number = max(existing) + 1`, so numbering continues across requeues; truncates `response_body` to 2048 bytes on a UTF-8 boundary, after `String.replace_invalid/1`.
  - `Webhooks.list_deliveries(job_id) :: [Delivery.t()]`, ordered by `number`.
  - `Webhooks.secret() :: String.t() | nil` from `config :distributed_task_queue, :webhooks, secret:`.

- [ ] **Step 1: Write the failing tests:**
  - `"header matches a known vector"`: for `body = ~s({"a":1})`, `secret = "s"` and `unix = 1_700_000_000`, assert `v1` equals the HMAC you computed in the test with `:crypto.mac(:hmac, :sha256, ...)`.
  - `"valid? rejects a tampered body and an old timestamp"`.
  - `"numbers deliveries 1, 2, 3 and keeps counting after a requeue"`: insert deliveries, reset `attempts` to 0 as a requeue does, insert one more, and assert the numbers are `[1, 2, 3, 4]`.
  - `"truncates and sanitises the response body"`: a 10 KB body with `<<0xFF>>` bytes is stored as at most 2048 bytes and passes `String.valid?/1`. (Review Focus 2.)
  - `"hard-deleting the job deletes its deliveries"`.
- [ ] **Step 2: Run** `mix test test/distributed_task_queue/webhooks` — Expected: FAIL.
- [ ] **Step 3: Implement**, then run `mix ecto.migrate` and `MIX_ENV=test mix ecto.migrate`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(webhooks): request signing and delivery history`

---

### Task 5: The webhook worker

**Files:**
- Create: `lib/distributed_task_queue/workers/webhook.ex`, `test/support/http_receiver.ex`
- Test: `test/distributed_task_queue/workers/webhook_test.exs`

**Interfaces:**
- Consumes: Task 1 `perform_job/1` and `{:discard, _}`; Task 2 `Request.normalize/1`; Task 3 `Target.check/2` and `Target.reason_text/1`; Task 4 `Signature.header/3`, `Webhooks.record_delivery/2` and `Webhooks.secret/0`.
- Produces:
  - `DistributedTaskQueue.Workers.Webhook` (`@behaviour DistributedTaskQueue.Worker`) with `perform_job(job)`, returning per the outcome table below.
  - `Workers.Webhook.module_name() :: "DistributedTaskQueue.Workers.Webhook"`.
- Test support: `HttpReceiver.start(responder :: (Plug.Conn.t() -> Plug.Conn.t())) :: base_url`.
  - It starts `Bandit` with `ip: :loopback, port: 0` under `start_supervised` and returns `"http://127.0.0.1:#{port}"`, getting the port from `ThousandIsland.listener_info/1`.
  - It also forwards each request to the test process as `{:received, method, path, headers, body}`.

Outcome table (spec A2): 2xx → `:ok`; 408/429/5xx/timeout/transport error → `{:error, reason}`; other 4xx, any 3xx, a `Target.check` error, or a payload that fails `Request.normalize` → `{:discard, reason}`. Reasons are plain English, e.g. `"The receiver rejected it (404 Not Found) — retrying would not help."` and `"No response within 15s."`.

- [ ] **Step 1: Write the failing tests**, using webhook jobs inserted with the factory and run through `Worker.run_job/1`:
  - `"2xx completes and records delivery 1 with status and body"`.
  - `"503 is retryable"`, `"429 is retryable"`, `"408 is retryable"`: `status == "retryable"`, with a delivery recorded.
  - `"404 dead-letters on the first attempt with a plain reason"`: `error_message =~ "rejected it (404"`.
  - `"302 dead-letters and says redirects are not followed"`; also assert the redirect target got no request.
  - `"connection refused is retryable"`: use a closed port.
  - `"a receiver that never answers times out"`: the responder sleeps 2 s and `timeout_ms` is 200. Expect `retryable` within 1 s, with an error that mentions the timeout. (Review Focus 1.)
  - `"sends service headers the caller cannot override"`:
    - The caller passes `"X-DTQ-Signature" => "forged"`, `"x-dtq-job-id" => "999"` and `"User-Agent" => "evil"`.
    - The received headers carry the job's real id and `x-dtq-attempt: 1`.
    - `user-agent` starts with `dtq-webhook/`.
    - The signature passes `Signature.valid?/3` with the configured secret.
    - (Review Focus 4.)
  - `"omits the signature when no secret is configured"`.
  - `"blocked target dead-letters without sending"`: use `allow_private_targets: false` and a `127.0.0.1` URL.
  - `"stores a huge response truncated"`: the receiver returns 100 KB, and the delivery has at most 2048 bytes. (Review Focus 2.)
- [ ] **Step 2: Run** `mix test test/distributed_task_queue/workers/webhook_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Send with `Finch.build/4` and `Finch.request/3`, using `name: DistributedTaskQueue.Finch` and `receive_timeout: timeout_ms`. Finch does not follow redirects.
  - The attempt number for `x-dtq-attempt` is `job.attempts + 1`.
  - Record a delivery for every attempt that got past validation, including timeouts.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(webhooks): webhook worker with signed, recorded deliveries`

---

### Task 6: API, queue bootstrap and production config

**Files:**
- Create: `lib/distributed_task_queue_web/controllers/webhook_controller.ex`
- Modify:
  - `lib/distributed_task_queue/webhooks.ex`
  - `lib/distributed_task_queue/queue_bootstrapper.ex`
  - `lib/distributed_task_queue_web/router.ex`
  - `lib/distributed_task_queue_web/controllers/job_controller.ex`
  - `lib/distributed_task_queue_web/controllers/cron_job_controller.ex`
  - `lib/distributed_task_queue/models/cron_job.ex`
  - `config/runtime.exs`
  - `fly.toml`
- Test: `test/distributed_task_queue_web/controllers/webhook_controller_test.exs`; additions to `job_controller_test.exs` and `cron_job_controller_test.exs`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces:
  - `Webhooks.enqueue(attrs :: map) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}`.
    - Accepts the spec A1 fields plus `"queue"` (default `"webhooks"`), `"max_attempts"` (default 5), and `"delay_seconds"` or `"run_at"` (ISO 8601), which becomes `scheduled_at`.
    - Runs `Request.normalize/1` and `Target.check/2`, putting their errors on the changeset under `:payload`, with `Target.reason_text/1` for the target ones.
    - Then calls `DistributedTaskQueue.add_job/2`.
  - `Webhooks.ensure_queue() :: :ok` — creates `webhooks` with concurrency 10 if missing. `QueueBootstrapper.do_boot/0` calls it first.
  - `Webhooks.cron_attrs(params :: map) :: map` — when `params["webhook"]` is present, sets `worker_module` and `payload`, the latter as the normalised request (validated as above).
  - `Webhooks.targets() :: :any | :demo_receivers`.
  - `CronJob.changeset/2` adds `validate_number(:interval_seconds, greater_than_or_equal_to: 10)` only when `Webhooks.targets() == :demo_receivers`.
  - `POST /api/webhooks` returns `201` with the job JSON, or `422`.
  - `job_json/1` gains `"deliveries"` for webhook jobs and redacts `payload.headers`.
  - runtime.exs (prod):
    - `config :distributed_task_queue, :webhooks, secret: DTQ_WEBHOOK_SECRET (raise if unset), targets: (if DTQ_WEBHOOK_TARGETS == "demo", do: :demo_receivers, else: :any), allow_private_targets: false`.
    - `DTQ_DEMO_API_KEY`, when set, is appended to `:api_keys` and also stored as `config :distributed_task_queue, :demo_api_key` (read by Task 12's intro).
  - `fly.toml` `[env]`: add `DTQ_WEBHOOK_TARGETS = "demo"`.

- [ ] **Step 1: Write the failing tests:**
  - `"POST /api/webhooks with delay_seconds schedules it"`: `201`, `scheduled_at` about 60 s ahead, `worker_module` is the webhook worker, queue `webhooks`, `max_attempts` 5.
  - `"POST /api/webhooks with run_at"`.
  - `"422 for a bad url, method or header"`.
  - `"422 for a non-receiver url in demo_receivers mode"`: set the mode via `Application.put_env` and restore it in `on_exit`.
  - `"GET /api/jobs/:id includes deliveries and redacts headers"`.
  - `"POST /api/cron_jobs accepts a webhook object"`.
  - `"cron interval below 10s is refused only in demo_receivers mode"`.
  - `"boot creates the webhooks queue once and never changes it"`: call `Webhooks.ensure_queue/0` twice, after editing concurrency to 3 between the calls, and assert it is still 3.
  - Runtime config: evaluate `Config.Reader.read!("config/runtime.exs", env: :prod)` in a test with env vars set, as an `@tag :config` test.
    - It raises without `DTQ_WEBHOOK_SECRET`.
    - The demo key is included in `api_keys`.
    - `DTQ_WEBHOOK_TARGETS=demo` gives `:demo_receivers`.
    - Restore env vars in `on_exit`.
- [ ] **Step 2: Run** the three controller test files — Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above. Add the route `post "/webhooks", WebhookController, :create` in the `/api` scope.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(api): POST /api/webhooks, webhook crons, deliveries in job JSON`

---

### Task 7: Console — "Call a URL" job form

**Files:**
- Create: `lib/distributed_task_queue_web/live/webhook_fields.ex`
- Modify: `lib/distributed_task_queue_web/live/jobs_live.ex`
- Test: `test/distributed_task_queue_web/live/console_live_test.exs` (new `describe "webhook jobs"`)

**Interfaces:**
- Consumes: `Webhooks.enqueue/1`, `Request.masked/0`, `Target.demo_receiver_names/0`, `Target.demo_receiver_url/1`, `Webhooks.targets/0`.
- Produces:
  - `DistributedTaskQueueWeb.WebhookFields.fields(assigns)`, a function component for the webhook part of a form.
    - Attrs: `form` (the `Phoenix.HTML.Form`), `targets` (`:any | :demo_receivers`) and `header_rows` (a list of `%{key, value}`). Used by Tasks 7 and 8.
    - In `:demo_receivers` mode it renders a receiver `<select>` in place of the URL input.
  - The form's `job[kind]` param is `"webhook"` (the default) or `"worker"` (today's fields).
  - `job[when]` is `"now"`, `"in"` (with `job[in_minutes]`) or `"at"` (with `job[run_at]`, a `datetime-local` interpreted as UTC). Header rows are added and removed with `phx-click="add_header"` / `"remove_header"`, using a row index.

- [ ] **Step 1: Write the failing tests:**
  - `"creating a webhook job from the form"`: fill URL, method and body, submit, and assert a job with the webhook worker exists and the flash says it was enqueued.
  - `"inline error for a bad URL"`.
  - `"demo_receivers mode shows a receiver picker, not a URL field"`.
  - `"run in 10 minutes sets scheduled_at"`.
  - `"the Elixir worker form still works"`: the existing create test, now with `kind: "worker"`.
- [ ] **Step 2: Run** `mix test test/distributed_task_queue_web/live/console_live_test.exs` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** `build_job/1` branches on `kind`. The webhook branch builds the attrs map from the form params and validates it with the same functions as `Webhooks.enqueue/1`, so the console and the API share one rule set.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(console): create webhook jobs without code`

---

### Task 8: Console — webhook cron jobs and plain-English schedules

**Files:**
- Create: `lib/distributed_task_queue_web/schedule_text.ex`
- Modify: `lib/distributed_task_queue_web/live/cron_live.ex`, `lib/distributed_task_queue_web/live/overview_live.ex`
- Test: `test/distributed_task_queue_web/schedule_text_test.exs`; `console_live_test.exs` (`describe "webhook crons"`)

**Interfaces:**
- Consumes: Task 7 `WebhookFields.fields/1`; `Webhooks.cron_attrs/1`; `Request.merge_masked/2`.
- Produces: `ScheduleText.describe(%CronJob{} | map) :: String.t()`. A small formatter over the parsed `Crontab` expression for the common shapes; anything else falls back to the raw expression.
  - Every N seconds/minutes/hours for interval schedules.
  - Every minute.
  - Every N minutes.
  - Every hour at :MM.
  - Every day at HH:MM.
  - Every <weekday(s)> at HH:MM.
  - Monthly on day D at HH:MM.
  - Plus " (Zone)" when a timezone is set.

- [ ] **Step 1: Write the failing tests:**
  - `ScheduleText.describe` should return:
    - `"Every 30 seconds"` for `interval_seconds: 30`
    - `"Every hour"` for `3600`
    - `"Every day at 02:00 (Africa/Nairobi)"` for `"0 2 * * *"` with that zone
    - `"Every Monday at 09:00"` for `"0 9 * * 1"`
    - `"Every 15 minutes"` for `"*/15 * * * *"`
    - `"On day 1 of every month at 00:00"` for `"0 0 1 * *"`
    - the expression itself for `"5 4 * 2-6 1,3"`
  - LiveView tests:
    - `"creating a webhook cron from the form"`.
    - `"the cron list and overview show the plain-English schedule"`.
    - `"editing a webhook cron without touching a redacted header keeps the secret"`: create a cron with an `authorization` header, open the edit form, submit unchanged, and assert the stored header is unchanged. (Review Focus 5.)
- [ ] **Step 2: Run** both test files — Expected: FAIL.
- [ ] **Step 3: Implement.** The cron form gets the same kind choice as Task 7. The edit path runs `Request.merge_masked/2` against the stored payload headers before validating.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(console): webhook cron jobs and plain-English schedules`

---

### Task 9: Console — delivery history on job detail

**Files:**
- Modify: `lib/distributed_task_queue_web/live/job_live.ex`
- Test: `console_live_test.exs` (`describe "job detail"`)

**Interfaces:**
- Consumes: `Webhooks.list_deliveries/1`, `Request.redact_headers/1`.
- Produces: for webhook jobs, the detail page renders:
  - The request (method, URL, redacted headers, body).
  - An attempts table: number, time, status code or error, duration, and a collapsible response snippet.
  - For a dead-lettered webhook, the stored `error_message` as the one-line reason.
  - Non-webhook jobs render as today.

- [ ] **Step 1: Write the failing tests:**
  - `"shows each delivery attempt"`.
  - `"never shows a credential header value"`: assert the real value is absent from the HTML and `••••` is present.
  - `"dead-lettered webhook shows the plain reason"`.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement.** Load deliveries in `refresh/1`, so the attempts table updates live as retries happen.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(console): webhook delivery history on job detail`

---

### Task 10: Demo receivers and their switches

**Files:**
- Create: `lib/distributed_task_queue/demo/receiver.ex`, `lib/distributed_task_queue/demo/receivers.ex`, `lib/distributed_task_queue_web/controllers/demo_receiver_controller.ex`, `priv/repo/migrations/20261104000002_create_demo_receivers.exs`
- Modify: `lib/distributed_task_queue_web/router.ex`
- Test: `test/distributed_task_queue/demo/receivers_test.exs`, `test/distributed_task_queue_web/controllers/demo_receiver_controller_test.exs`

**Interfaces:**
- Consumes: `Target.demo_receiver_names/0`.
- Produces:
  - Migration `demo_receivers`: `name` (string, unique), `online` (bool, default true), `offline_until` (`utc_datetime`, null), `failure_rate` (float, default 0.1), timestamps.
  - `Receivers.ensure_all() :: :ok` — inserts a missing row per name. Never overwrites. Rates: payments 0.05, email 0.1, warehouse 0.15 (my call).
  - `Receivers.list() :: [Receiver.t()]`; `Receivers.online?(name) :: boolean`. A row whose `offline_until` is in the past counts as online and is flipped back lazily.
  - `Receivers.set_online(name, boolean) :: {:ok, Receiver.t()}` — offline sets `offline_until = now + 300 s`. Broadcasts `[:dtq, :console, :demo_changed]` through `Events.broadcast/2`.
  - `POST|GET|PUT|PATCH|DELETE /demo/receivers/:name`, in a scope piped through a new `:demo_receiver` pipeline (`plug :accepts, ["json"]`) with no auth. It returns:
    - 404 unless `Application.get_env(:distributed_task_queue, :demo_mode)`, and for an unknown name.
    - 503 `{"error": "<Name> is offline"}` when the receiver is offline.
    - Otherwise a 50–800 ms delay, then 503 with probability `failure_rate`, else 200 `{"ok": true, "receiver": name}`.
    - The delay range is read from `config :distributed_task_queue, :demo_receiver_delay_ms, 50..800`; test config sets `0..0`.

- [ ] **Step 1: Write the failing tests:**
  - `"offline receivers come back on their own after 5 minutes"`: set `offline_until` in the past and assert `online?` is true.
  - `"set_online(false) sets offline_until 5 minutes ahead"`.
  - `"ensure_all is idempotent and keeps edits"`.
  - Controller tests:
    - `"404 when demo mode is off"`.
    - `"503 while offline"`.
    - `"200 when online with failure_rate 0"`.
    - `"404 for an unknown receiver"`.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement**, then migrate dev and test.
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(demo): in-app demo receivers with online/offline switches`

---

### Task 11: The Acme Store scenario

**Files:**
- Create: `lib/distributed_task_queue/demo/order_worker.ex`
- Modify: `lib/distributed_task_queue/demo.ex`
- Test: `test/distributed_task_queue/demo_test.exs`

**Interfaces:**
- Consumes: `Webhooks.enqueue/1`, `Target.demo_receiver_url/1`, `Receivers.ensure_all/0`.
- Produces:
  - `Demo.OrderWorker` (`@behaviour Worker`) — `perform/1` makes one order (`"order_id"`, random `"total"`, `"customer"` from a fixed list). It enqueues three webhooks on the `webhooks` queue, one each to `payments`, `email` and `warehouse`, with the order as the JSON body.
  - `Demo.seed/0` now:
    - Calls `Webhooks.ensure_queue/0` and `Receivers.ensure_all/0`.
    - Deletes the cron rows named `demo-burst` and `demo-nightly-report` if present.
    - Creates, if missing: a queue `demo` (kept) for the order cron; a cron `acme-orders` (`interval_seconds: 10`, `overlap: true`, worker `Demo.OrderWorker`, queue `demo`); and a webhook cron `acme-daily-sales-report` (`interval_seconds: 60`, target `email`, body `{"report": "daily-sales"}`).
    - The `demo-reports` queue from the earlier demo is no longer created.
  - `Demo.prune/0` also covers the `webhooks` queue. Deliveries go with their jobs through the cascade.

- [ ] **Step 1: Write or adjust the failing tests:**
  - `"an order enqueues three webhooks to the three receivers"`.
  - `"seed retires the old demo crons by name"`.
  - `"seed creates the Acme crons once"`.
  - `"prune removes old webhook jobs and their deliveries"`.
  - Update the existing seed test for the new names.
- [ ] **Step 2: Run** `mix test test/distributed_task_queue/demo_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(demo): Acme Store order pipeline over webhooks`

---

### Task 12: Demo controls and the plain-English layer

**Files:**
- Create: `lib/distributed_task_queue_web/live/demo_controls.ex`
- Modify:
  - `lib/distributed_task_queue_web/live/overview_live.ex`
  - `lib/distributed_task_queue_web/components/console_components.ex` (status tooltips)
  - `lib/distributed_task_queue_web/live/jobs_live.ex` (node header tooltip)
  - `assets/js/app.js` (intro dismissal hook)
- Test: `console_live_test.exs` (`describe "demo"`)

**Interfaces:**
- Consumes: `Receivers.list/0`, `Receivers.set_online/2`.
- Produces:
  - `DemoControls.panel(assigns)` with an attr `receivers`. It renders one switch per receiver, with `phx-click="toggle_receiver"` and `phx-value-name`, and a "back online at HH:MM" note while offline. Shown on the Overview only when `demo_mode` is on.
  - Overview intro, with `id="demo-intro"` and `phx-hook="DismissOnce"`:
    - One sentence on what this is.
    - Three "try this" steps.
    - Links to the repo and the writeups.
    - The demo API key, plus one `curl` example against a receiver, when `DTQ_DEMO_API_KEY` is set (read via `Application.get_env(:distributed_task_queue, :demo_api_key)`, which `runtime.exs` sets).
  - The JS hook `DismissOnce` hides the element when `localStorage["dtq:intro-dismissed"] == "1"` and sets that key on the dismiss button's click. Wrap storage access in try/catch.
  - `job_status/1` gets a `title` tooltip from `status_hint(job) :: String.t()`:
    - pending: "Waiting its turn"
    - started: "Running now"
    - retryable: "Failed — will try again at HH:MM" (from `next_retry_at`)
    - completed: "Done"
    - dead letter: "Gave up after N tries"
  - The Node column header gets the tooltip "Which server ran it".

- [ ] **Step 1: Write the failing tests:**
  - `"demo controls toggle a receiver offline and back"`: click and assert `Receivers.online?("warehouse") == false`, then click again.
  - `"demo controls are hidden outside demo mode"`.
  - `"intro shows the demo key and curl example when configured"`.
  - `"status badges explain themselves"`: a retryable job's badge `title` contains "will try again at".
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement.** Copy must be readable by a non-coder, compact, and dismissible (spec C3).
- [ ] **Step 4: Run** `mix test` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(demo): demo controls, intro and plain-English statuses`

---

### Task 13: Documentation and end-to-end check

**Files:**
- Modify: `README.md`, vault notes `C:\Users\Abwape\Documents\Obsidian Vault\Me\Elixir\Distributed Task Queue - Portfolio Plan.md` and `...Project Status.md`

- [ ] **Step 1: README.**
  - Rewrite the one-line pitch around "a job service any app can hand HTTP work to".
  - Add a *Webhooks* section: the API, outcome table, signature verification snippet (receiver side, any language), idempotency via `x-dtq-job-id`, target safety and the demo mode.
  - Add the new env vars to *Authentication* / *Deploying*.
  - Add the residual DNS-rebinding risk and unencrypted stored header values to *Known limitations*.
- [ ] **Step 2: End-to-end run in dev.**
  - Run `DTQ_DEMO_MODE=true mix phx.server`.
  - Expected within 60 s: webhook jobs completing on `webhooks`, and the deliveries visible on a job's detail page.
  - Switching Warehouse offline shows warehouse jobs retrying, and switching it back drains them.
  - Then delete the demo crons from the dev DB, since they persist (see the README note).
- [ ] **Step 3: Run** `mix test`, `mix compile --warnings-as-errors`, `mix credo --strict` — Expected: tests pass; credo shows no issues beyond the 6 pre-existing ones.
- [ ] **Step 4: Update the vault.**
  - Mark the direction-change section "built".
  - Rewrite the résumé bullet per the note there.
  - Add a *What Shipped* entry to Project Status.
- [ ] **Step 5: Commit** `docs: webhook job service`
