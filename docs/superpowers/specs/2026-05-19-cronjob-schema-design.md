# Cron Job Schema Design

**Date:** 2026-05-19
**Status:** Approved

## Overview

Add a `cron_jobs` table that defines recurring job schedules. Each time a cron fires it inserts a row into the existing `jobs` table, which flows through the normal queue/worker pipeline unchanged.

---

## Database Schema

### New table: `cron_jobs`

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigserial | PK | |
| `name` | string | unique, not null | Human-readable identifier |
| `description` | text | nullable | |
| `worker_module` | string | not null | Mirrors `jobs.worker_module` |
| `queue_name` | string | not null | Must reference an existing queue |
| `payload` | map | not null, default `%{}` | Passed to worker on each fire |
| `max_attempts` | integer | default 3 | Applied to each spawned job |
| `cron_expression` | string | nullable | Standard 5-field cron, e.g. `"0 9 * * 1"` |
| `interval_seconds` | integer | nullable | Simple recurring interval, e.g. `300` |
| `overlap` | boolean | not null, default false | If false, skip fire when prior run still active |
| `enabled` | boolean | not null, default true | Pause without deleting |
| `last_run_at` | utc_datetime | nullable | Set after each fire |
| `next_run_at` | utc_datetime | nullable | Precomputed; drives scheduler polling |
| `inserted_at` | utc_datetime | not null | |
| `updated_at` | utc_datetime | not null | |

**Check constraint:** exactly one of `cron_expression` or `interval_seconds` is non-null.

**Indexes:**
- Unique on `name`
- Composite on `(next_run_at, enabled)` — efficient polling query

### Change to existing `jobs` table

Add a nullable `cron_job_id` foreign key referencing `cron_jobs.id`. Set on all jobs spawned by a cron fire; null for manually enqueued jobs. Used for overlap detection.

---

## Integration with the Jobs Pipeline

The existing `jobs` table, `QueueManager`, `WorkerSupervisor`, and `Worker` are unchanged. A cron-spawned job is a regular job with `cron_job_id` populated.

### Fire flow

```
CronScheduler (new GenServer)
  │
  ├─ Poll: SELECT * FROM cron_jobs
  │        WHERE next_run_at <= now AND enabled = true
  │
  ├─ For each due cron:
  │    ├─ overlap = false?
  │    │    └─ SELECT 1 FROM jobs
  │    │         WHERE cron_job_id = X AND status IN ('pending', 'running')
  │    │         → if any exist: skip this fire
  │    │
  │    ├─ INSERT INTO jobs
  │    │    (worker_module, queue_name, payload, max_attempts, cron_job_id, ...)
  │    │    ↓ normal pipeline: QueueManager → WorkerSupervisor → Worker
  │    │
  │    └─ UPDATE cron_jobs
  │         SET last_run_at = now,
  │             next_run_at = <computed from cron_expression or interval_seconds>
  │
  └─ Sleep until MIN(next_run_at) across all enabled cron jobs
       (same pattern as QueueManager.next_retryable_delay/1)
```

---

## Ecto Model: `CronJob`

New module `DistributedTaskQueue.CronJob` with an Ecto schema mirroring the table.

### Changeset validation

- Required: `name`, `worker_module`, `queue_name`
- `payload` required, defaults to `%{}`
- Exactly one of `cron_expression` or `interval_seconds` — enforced in changeset (custom validation) and at DB level (check constraint)
- `cron_expression` validated against a basic 5-field cron regex
- `interval_seconds` validated to be a positive integer
- `overlap` defaults to `false`, `enabled` defaults to `true`

---

## Context Functions

New functions added to the `DistributedTaskQueue` context module, following existing patterns:

| Function | Purpose |
|---|---|
| `create_cron_job/1` | Insert cron job; compute initial `next_run_at` |
| `list_cron_jobs/0` | Return all cron jobs |
| `get_cron_job/1` | Fetch by id |
| `update_cron_job/2` | Update fields; recompute `next_run_at` if schedule changed |
| `delete_cron_job/1` | Hard delete |
| `enable_cron_job/1` | Set `enabled = true` |
| `disable_cron_job/1` | Set `enabled = false` |

---

## New Module: `CronScheduler`

A GenServer added to the application supervision tree alongside `QueueManager` and `WorkerSupervisor`.

Responsibilities:
- On start: compute `next_run_at` for any cron jobs where it is null
- Poll DB for due cron jobs
- Enforce overlap policy
- Spawn jobs into the existing pipeline
- Update `last_run_at` and `next_run_at` after each fire
- Self-schedule next wake using `Process.send_after/3` based on earliest `next_run_at`

---

## What Is Not In Scope

- API endpoints for CRUD on cron jobs (separate concern)
- Cron expression parsing library choice (decided at implementation time)
- Distributed leader election (single-node scheduler for now)
