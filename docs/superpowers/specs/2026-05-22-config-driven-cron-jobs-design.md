# Config-Driven Cron Jobs Design

**Date:** 2026-05-22  
**Status:** Approved

## Problem

Cron job schedules must currently be inserted manually into the `cron_jobs` table. There is no way to define them declaratively in code. Additionally, the `cron_job_id` field on `Job` is a bare integer with no Ecto association, losing preload and FK enforcement.

## Decision

Keep the two-table architecture (`cron_jobs` + `jobs`) — it is correct. The template/instance separation is intentional: `cron_jobs` rows are schedule definitions; `jobs` rows are execution instances. The duplicated fields (`worker_module`, `queue_name`, `payload`, `max_attempts`) on `Job` are deliberate snapshots taken at fire time so in-flight jobs are unaffected by schedule changes.

The missing piece is config-driven cron job definitions.

## Design

### 1. Config Format

Cron jobs are defined in `config/config.exs` (or environment-specific config files):

```elixir
config :distributed_task_queue, :cron_jobs, [
  %{
    name: "daily_report",
    worker_module: "MyApp.DailyReportWorker",
    queue_name: "default",
    cron_expression: "0 9 * * *",
    payload: %{},
    max_attempts: 3,
    overlap: false
  },
  %{
    name: "cleanup_old_jobs",
    worker_module: "MyApp.CleanupWorker",
    queue_name: "low",
    interval_seconds: 3600
  }
]
```

Each map entry corresponds 1:1 to a `cron_jobs` row. Optional fields (`max_attempts`, `overlap`, `payload`) fall back to schema defaults if omitted. `name` is the unique conflict key — it must be stable across deployments.

### 2. Startup Upsert Behavior

`CronScheduler.init/1` reads `Application.get_env(:distributed_task_queue, :cron_jobs, [])` and upserts each entry into `cron_jobs` using `name` as the conflict key via Ecto's `on_conflict` with `conflict_target: :name`.

Behavior per case:

| Scenario | Result |
|---|---|
| First boot | Row inserted fresh |
| Changed `cron_expression` or `interval_seconds` | Row updated; `next_run_at` recomputed |
| Removed from config | Row stays in DB, continues running |
| Manually inserted row (not in config) | Untouched by upsert |

Removed entries are **not** auto-disabled. To stop a cron job removed from config, set `enabled: false` manually or delete the row. This keeps startup behavior predictable — nothing disappears implicitly.

### 3. Ecto Association Fix

`Job.cron_job_id` is currently a bare integer field. It becomes a proper association:

```elixir
# In Job schema
belongs_to :cron_job, DistributedTaskQueue.CronJob

# In CronJob schema
has_many :jobs, DistributedTaskQueue.Job
```

The existing `cron_job_id` integer column in the DB does not change — only the schema declaration changes. This enables `Repo.preload`, proper FK enforcement at the Ecto level, and cleaner queries.

## What Does Not Change

- One-off jobs: insert a `Job` directly with no `cron_job_id` — already works, no changes needed.
- Dynamic cron jobs: insert a `CronJob` row directly at runtime — still works alongside config-defined jobs.
- `CronScheduler` polling and firing logic — unchanged.
- DB schema for `cron_jobs` and `jobs` tables — no new migrations needed beyond the association fix.

## Out of Scope

- Auto-disabling cron jobs removed from config
- Worker module-level schedule declarations
- UI for managing cron jobs
