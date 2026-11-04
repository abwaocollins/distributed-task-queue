# Webhook Job Service Design

**Date:** 2026-11-04
**Status:** Draft for approval

---

## Intent

Turn the project from "an Elixir job queue" into **a job service any app can use, in any language**: an app hands it an HTTP request to make — now, later, or on a schedule — and the service makes sure it is delivered, retrying through failures and setting aside what keeps failing.

The project is a portfolio piece. The owner's goal, in their words: something that "can be checked and attracts attention of recruiters and fellow developers, and it has to be practical". Two readers matter:

- **A recruiter** who clicks the live demo and cannot read code. They should understand what it does in one sentence — *it makes sure scheduled tasks actually happen, even when things break* — and see that happen on screen within a minute.
- **A developer** who reads the code. The existing coordination work (race-safe claiming, cron tick claiming, orphan reaper, dead-letter queue, auth) is what makes a delivery service trustworthy. The webhook layer must visibly *build on* that, not sit beside it.

Why this direction: today the only real worker is `EmailWorker`, which logs a line, and every new kind of work needs Elixir code. A built-in "call this URL" job is genuinely useful to a team on any stack, and it is a recognisable product category (hosted delayed / scheduled webhook services), which gives the project a crisp real-world story.

## Goals

1. **Webhook jobs.** A job that makes one HTTP request. Success, retry and dead-letter follow the rules below. Every attempt is recorded.
2. **Usable without code.** Webhook jobs and webhook cron jobs can be created entirely from console forms, including a plain-English reading of the schedule.
3. **A simple HTTP API** for other apps to hand over work: one call for a one-off or delayed webhook, and the existing cron API for recurring ones.
4. **Receivers can trust and dedupe deliveries.** Requests are signed, and carry a stable id so a receiver can ignore duplicates (delivery is at-least-once).
5. **A demo a recruiter understands.** A realistic scenario, plain-English explanations, and a way for a visitor to *cause* a failure and watch the system recover.

## Non-goals

- Built-in integrations (Slack, email providers, etc.). A webhook can call any of them; the service doesn't know them by name.
- Multiple accounts or tenants. One deployment, one set of API keys.
- Workflows: chaining jobs, branching on a response, fan-out.
- Honouring `Retry-After` headers. The existing exponential backoff applies to every retry.
- Exactly-once delivery. Delivery is at-least-once; the idempotency header is how receivers cope.
- Following HTTP redirects.

## Anti-goals (failures even if it technically works)

- **Becoming a Zapier clone.** A library of point-and-click integrations is a different product, and would bury the engineering story.
- **Weakening the code-execution boundary.** Nothing in the console or API may make the service run arbitrary code. Webhooks make HTTP requests; `Worker.resolve/1` stays the only way to reach Elixir code.
- **Becoming an open proxy.** The public demo must not let a visitor make the server request internal addresses (cloud metadata, the database, localhost services).
- **Breaking existing jobs.** Jobs with an Elixir `worker_module` keep working unchanged, from the API and the console.
- **A demo that needs explaining.** If a recruiter has to read the README to see what happened, the demo has failed.

## Constraints

- Builds on the current codebase: Phoenix 1.7, LiveView 1.1, Ecto/Postgres, `Finch` (already a dependency). Webhook jobs are ordinary rows in `jobs`, claimed and retried by the existing `QueueManager` / `Worker` path.
- Existing behaviour the design relies on: exponential backoff (`min(15 × 2^attempts, 3600)` s), dead-letter on exhausted attempts, `scheduled_at` for delayed jobs, cron with timezones, the orphan `Reaper`, API keys and admin basic auth (`DistributedTaskQueueWeb.Auth`), demo mode (`DTQ_DEMO_MODE`).
- The deployment target is Fly.io as a public demo (`fly.toml` sets `DTQ_PUBLIC_CONSOLE=true` and `DTQ_DEMO_MODE=true`), so anything a visitor can trigger must be safe on the open internet.

---

## Part A — The webhook job type

### A1. What a webhook job is

A built-in worker (my call on the name: `DistributedTaskQueue.Workers.Webhook`) declaring `@behaviour DistributedTaskQueue.Worker`, so it goes through the existing dispatch and security boundary. Its payload:

| Field | Required | Default | Notes |
|---|---|---|---|
| `url` | yes | | `http` or `https` only |
| `method` | no | `POST` | `GET`, `POST`, `PUT`, `PATCH`, `DELETE` |
| `headers` | no | `{}` | string → string |
| `body` | no | none | a string, or a JSON object/array, which is encoded and sent with `content-type: application/json` unless a content type is given |
| `timeout_ms` | no | 15 000 | capped at 60 000 |

The payload is validated **when the job is created** (422 from the API, inline errors in the console), not first discovered at delivery time.

### A2. Outcome rules

| Response | Outcome |
|---|---|
| any 2xx | completed |
| 408, 429, any 5xx | failed attempt → retry with the existing backoff, dead-letter when attempts run out |
| timeout, connection refused, DNS failure, TLS error | failed attempt → retry |
| any other 4xx (400, 401, 404, 422, …) | **permanent**: dead-letter immediately, no further attempts |
| a 3xx | permanent (redirects are not followed); the error says so |
| a target blocked by A5 | permanent |

Dead-lettering a permanent failure straight away needs a small extension to the worker contract: `perform/1` may return `{:discard, reason}` to skip remaining attempts. Existing workers returning `:ok` / `{:error, _}` are unaffected.

### A3. What gets sent

Every request carries these headers, which a caller-supplied header of the same name cannot override:

- `user-agent: dtq-webhook/<version>`
- `x-dtq-job-id` — the job id, stable across retries. Receivers should use it to ignore duplicates.
- `x-dtq-attempt` — 1-based attempt number.
- `x-dtq-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">`, keyed with `DTQ_WEBHOOK_SECRET`. This is the same scheme Stripe uses, so receivers can verify both that the request came from this service and how old it is. When the secret is unset (dev/test) the header is omitted. In production the app should refuse to start without it, matching how admin credentials are handled.

### A4. Delivery history

Every attempt is recorded in a new `webhook_deliveries` table: job, attempt number, request URL and method, response status (if any), duration, the first 2 KB of the response body, the error (if any), and when it happened. The console's job detail page shows this as an attempts table. It is what lets a person answer "did it fail, why, and did it eventually get through?" without reading logs.

When a job is deleted, its deliveries go with it (cascade). Demo pruning removes them along with the jobs it prunes.

### A5. Not an open proxy (SSRF)

Before connecting, the resolved address of the target must not be private, loopback, link-local (including `169.254.169.254` cloud metadata), unique-local IPv6, or unspecified. Blocked targets fail permanently with a clear message. Redirects are never followed, so a public URL cannot bounce the request inward.

- `config :distributed_task_queue, :webhooks, allow_private_targets: true` turns the check off. It is **on in dev and test**, so `localhost` receivers work while developing, and **off in production**.
- The demo receiver (Part C) runs inside this same app. In production it must still be reachable even though the app's own address is private. How to allow exactly that one target without opening private addresses generally is left to the builder; one valid approach is to call it in-process rather than over the network.
- Known residual risk, to be written up in the README's limitations: DNS rebinding between the check and the connection, unless the builder pins the connection to the address that was checked.

### A5b. Webhook targets on the public demo (owner decision, 2026-11-04)

Blocking private addresses is not enough on a public deployment. An open console with a free URL field would let any visitor make the server send signed, retried requests to any website, as often as every second.

So there is a deployment-wide target mode (my call on the name: `config :distributed_task_queue, :webhooks, targets: :any | :demo_receivers`):

- **`:any`** (the default) — any public `http(s)` URL, subject to A5. This is what someone running their own copy gets.
- **`:demo_receivers`** — webhooks may only target the in-app demo receivers (Part C). Anything else is rejected when the job is created (422 / inline error), and again at delivery time for jobs that predate a mode change. The live demo runs this way: `fly.toml` sets it alongside `DTQ_PUBLIC_CONSOLE` and `DTQ_DEMO_MODE`.

In `:demo_receivers` mode:

- **The console's "Call a URL" form** offers a choice of receiver (Payments, Email, Warehouse) instead of a free URL field. Method, headers, body and timing stay editable.
- **A demo API key is published.** It is set as `DTQ_DEMO_API_KEY`, accepted alongside `DTQ_API_KEYS`, and printed in the README and the demo intro.
  - A developer can `curl` the live site to schedule a webhook to a demo receiver, then watch their job appear in the console, fail while that receiver is offline, and get delivered when it comes back.
  - The key needs no special scope: the target mode applies to the whole deployment, so no key can reach anything else.
- **Cron jobs have a 10-second minimum interval** (my call), so the demo can't be made to hammer itself.

### A6. Secrets in headers

Callers will put credentials for *their* service in `headers` (e.g. `authorization`). Those values are stored in the job payload, but they must not be **displayed**: the console and the API responses redact the values of `authorization`, `cookie`, `proxy-authorization`, and any header whose name contains `token`, `secret`, `key` or `signature`, showing `••••` instead. Encrypting payloads at rest is out of scope; the README says so.

---

## Part B — Handing over work

### B1. HTTP API

- **`POST /api/webhooks`**: create a one-off webhook job.
  Body: the A1 fields, plus optional `queue` (default `webhooks`), `max_attempts` (default 5), and either `delay_seconds` or `run_at` (ISO 8601) for later delivery.
  Returns `201` with the job, including its id, which the caller can use with `GET /api/jobs/:id`.
- **Recurring webhooks** go through the existing `POST /api/cron_jobs`, accepting a `webhook` object (the A1 fields) in place of `worker_module` + `payload`.
- **Existing endpoints are unchanged.** `POST /api/jobs` still accepts a `worker_module`, and a webhook job can also be created there by naming the webhook worker and passing its payload.
- **`GET /api/jobs/:id`** includes the delivery attempts for webhook jobs.

A `webhooks` queue exists out of the box: created at boot if missing, never overwritten. My call on concurrency: 10.

### B2. Console

- **New job form:** a choice between "Call a URL" (the default) and "Run an Elixir worker" (today's form).
  - The webhook fields are URL, method, headers as add/remove key–value rows, body, and when to run: now, in N minutes, or at a date and time.
  - The form validates inline, as the existing forms do.
- **New cron form:** the same choice. Alongside the cron expression, the console shows the schedule in plain English, e.g. "Every day at 02:00 (Africa/Nairobi)". It also shows this reading in the cron list and on the overview's "next runs".
- **Job detail:** the attempts table (A4), the request that will be or was sent (headers redacted per A6), and for a dead-lettered webhook a one-line reason in plain words, e.g. "The receiver rejected it (404 Not Found) — retrying would not help."

How the plain-English schedule is produced (a library or a small formatter for the common shapes, with a graceful fallback to the raw expression) is left to the builder.

---

## Part C — A demo a recruiter understands

### C1. The scenario: an online shop

Demo mode replaces today's `DemoWorker` cron jobs with a story told entirely through webhooks. My call on the name and details; the builder may adjust them:

- A fictional shop, **"Acme Store"**, places an order every ~10 seconds.
- Each order creates three webhook jobs, to three in-app **demo receivers**: *Payments* (charge the card), *Email* (send the receipt) and *Warehouse* (pack and ship).
- Each receiver is a route inside the app that answers like a real service: a short random delay, and a small configurable chance of failing with a 503.
- A nightly-style cron webhook ("Daily sales report", every minute in demo mode) shows the scheduled side.

Retries and the dead-letter queue then fill naturally with failures that make sense to a non-coder ("the warehouse didn't answer, so we'll try again in 30 seconds").

The existing `DemoWorker` stays in the codebase; it is still useful for tests and for showing an Elixir worker.

### C2. Let the visitor break something

A small **"Demo controls"** panel, visible only in demo mode:

- A switch per receiver: **Online / Offline**. Offline makes that receiver return `503` to everything.
- The expected experience: switch the Warehouse offline and its jobs start failing and retrying, with growing delays. Switch it back on and the backlog drains. Anything that ran out of attempts lands in Dead letter, where the visitor can press Requeue.
- Switches reset to Online on their own after 5 minutes (my call), so one visitor can't leave the demo broken for the next.

This is the moment that sells the project to a non-technical viewer, and it is cheap to build on top of the receivers.

### C3. Plain-English layer

- **A short intro on the Overview page.** It shows on a first visit, can be dismissed, and is remembered per browser. It contains:
  - One sentence on what this is.
  - Three "try this" steps: take a receiver offline; watch the jobs retry; requeue one from Dead letter.
  - A link to the source and the engineering writeups.
- **Statuses read as words.** Each status badge carries a plain description in its tooltip: pending is "waiting its turn", retryable is "failed — will try again at 14:02", and dead letter is "gave up after 5 tries".
- **The node column says what it means.** Its header tooltip reads "which server ran it".

Exact copy is left to the builder, but it must be readable by someone who has never written code. It must also stay out of the way for developers: compact, and dismissible.

---

## Decided

**By the owner:**
- The direction: a webhook job service, as a portfolio piece aimed at recruiters and developers that must be practical.
- Deployed as an app, not a library (2026-09-23).
- On the public demo, webhooks may only target the built-in demo receivers, and a demo API key with the same limit is published (A5b).

**My calls** (flagged for review):
- The A2 outcome table: which responses retry and which are permanent.
- The signing scheme (Stripe-style) and the header names.
- SSRF blocking on by default in production, off in dev and test.
- Redacting credential-like header values on display.
- The `webhooks` queue with concurrency 10, and `max_attempts` default 5 for webhooks.
- The Acme Store scenario, receiver switches with a 5-minute auto-reset, and the dismissible intro.

**Settled during review** (my calls, from points the reviewer raised):
- **The worker gets job context.** `perform/1` receives only the payload today. The webhook worker also needs the job id and attempt number for its headers and delivery rows, so the worker contract gains an optional way to receive the job, alongside `{:discard, reason}`. Existing workers are unaffected.
- **Delivery history survives a requeue.** Requeue resets `attempts` to 0, so delivery rows are numbered by delivery count across the job's whole life. Attempt numbers then never clash.
- **Cascade covers hard deletes only.** Console and API deletes are soft (`deleted_at`), and soft-deleted jobs keep their history. Hard deletes go through a foreign key with `on_delete: :delete_all`: `Demo.prune`, `delete_queue` and `hard_delete_job`.
- **The old demo crons are retired.** `demo-burst` and `demo-nightly-report` are removed by name when demo mode seeds the new scenario. Otherwise they keep firing on any database that already has them.
- **Demo switches are shared state.** Receiver Online/Offline lives in the database, so every node and every visitor sees the same switch.
- **Editing keeps redacted secrets.** A header value left as `••••` in an edit form means "keep the stored value", never "replace it with dots".

## Left to the builder

- The HTTP client (Finch is already a dependency).
- Module layout and naming, beyond the worker being a normal `Worker` module.
- How the demo receiver is exempted from SSRF blocking in production.
- How to render plain-English schedules.
- The exact UI layout and copy, within the existing console's components and style.
- Whether `webhook_deliveries` rows are written by the worker directly or via a context function.
- The order of work. Suggested: Part A → B → C, since the demo depends on the first two.

## Done means

- A Python or Node app can schedule a delayed webhook with one `curl`-able request, and later read back its delivery attempts. On the live demo, this works with the published demo key against a demo receiver.
- On the live demo, a webhook to any URL other than a demo receiver is refused, from both the console and the API.
- A webhook to a receiver that is down for a while gets delivered once it comes back, within the retry window.
- A 404 goes straight to dead letter, with a reason that says why retrying wouldn't help.
- `http://169.254.169.254/` and `http://localhost:5432/` are refused in production.
- On the live demo, a visitor who has never coded can take the Warehouse offline, watch retries happen, bring it back, and requeue a dead job, without reading anything but the screen.
- The existing test suite still passes. New behaviour is covered at the same standard as the rest of the codebase, including the outcome table, signing, SSRF blocking and redaction.
