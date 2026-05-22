# Config-Driven Cron Jobs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow cron jobs to be declared in `config.exs` and automatically upserted into the database on startup, with no manual DB inserts required.

**Architecture:** `DistributedTaskQueue.upsert_cron_jobs_from_config/0` reads `Application.get_env(:distributed_task_queue, :cron_jobs, [])` and upserts each entry into `cron_jobs` using `name` as the conflict key; `CronScheduler.init/1` calls it before `initialize_null_next_run_ats/0`. The existing two-table architecture (`cron_jobs` + `jobs`) is unchanged — only the declaration UX improves. The `Job` schema's bare `field :cron_job_id, :integer` is upgraded to a proper `belongs_to` association.

**Tech Stack:** Elixir, Ecto, PostgreSQL, ExUnit

---

## File Map

| File | Change |
|---|---|
| `lib/distributed_task_queue/models/job.ex` | Replace bare `field :cron_job_id` with `belongs_to :cron_job` |
| `lib/distributed_task_queue/models/cron_job.ex` | Add `has_many :jobs` |
| `lib/distributed_task_queue.ex` | Add `upsert_cron_jobs_from_config/0` |
| `lib/distributed_task_queue/cron_scheduler.ex` | Call `upsert_cron_jobs_from_config/0` in `init/1` |
| `config/config.exs` | Add `config :distributed_task_queue, :cron_jobs, []` with format comment |
| `test/distributed_task_queue_test.exs` | Add tests for `upsert_cron_jobs_from_config/0` |
| `test/distributed_task_queue/cron_scheduler_test.exs` | Add test that config seeding runs on init |

---

## Task 1: Fix Ecto Associations

**Files:**
- Modify: `lib/distributed_task_queue/models/job.ex`
- Modify: `lib/distributed_task_queue/models/cron_job.ex`
- Test: `test/distributed_task_queue/cron_job_test.exs`

The existing `field :cron_job_id, :integer` on `Job` is a bare integer with no Ecto association — you can't `Repo.preload(:cron_job)`. Replacing it with `belongs_to` makes the FK a first-class Ecto relationship. The `belongs_to` macro automatically defines the `cron_job_id` field, so the existing `cast` list and the existing test (`"cron_job_id is castable"`) continue to work without changes.

- [ ] **Step 1: Write the failing test**

Open `test/distributed_task_queue/cron_job_test.exs` and add this test inside the existing `describe "Job changeset accepts cron_job_id"` block, after the existing test:

```elixir
test "belongs_to association allows preloading cron_job" do
  cron = insert(:cron_job)
  {:ok, job} = DistributedTaskQueue.add_job(cron.queue_name, %{
    "worker_module" => cron.worker_module,
    "payload" => %{},
    "cron_job_id" => cron.id
  })

  loaded = DistributedTaskQueue.Repo.preload(job, :cron_job)
  assert loaded.cron_job.id == cron.id
end
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
mix test test/distributed_task_queue/cron_job_test.exs --only "belongs_to association"
```

Expected: error like `key :cron_job not found in %DistributedTaskQueue.Job{}` or `undefined field :cron_job`.

- [ ] **Step 3: Replace the bare field with `belongs_to` in Job**

In `lib/distributed_task_queue/models/job.ex`, replace:

```elixir
field(:cron_job_id, :integer)
```

with:

```elixir
belongs_to(:cron_job, DistributedTaskQueue.CronJob)
```

The `cast` list in `changeset/2` already includes `:cron_job_id` — leave it as-is. `belongs_to` generates `cron_job_id` automatically as the foreign key field.

- [ ] **Step 4: Add `has_many :jobs` to CronJob**

In `lib/distributed_task_queue/models/cron_job.ex`, add after the `timestamps()` line:

```elixir
has_many(:jobs, DistributedTaskQueue.Job)
```

The full schema block should end:

```elixir
    field :next_run_at, :utc_datetime

    has_many(:jobs, DistributedTaskQueue.Job)
    timestamps()
  end
```

- [ ] **Step 5: Run all existing cron tests to confirm nothing broke**

```bash
mix test test/distributed_task_queue/cron_job_test.exs
```

Expected: all pass, including `"cron_job_id is castable"`.

- [ ] **Step 6: Run the new preload test**

```bash
mix test test/distributed_task_queue/cron_job_test.exs
```

Expected: all pass including `"belongs_to association allows preloading cron_job"`.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue/models/job.ex \
        lib/distributed_task_queue/models/cron_job.ex \
        test/distributed_task_queue/cron_job_test.exs
git commit -m "refactor: replace bare cron_job_id field with belongs_to association"
```

---

## Task 2: Add `upsert_cron_jobs_from_config/0` to Context

**Files:**
- Modify: `lib/distributed_task_queue.ex`
- Test: `test/distributed_task_queue_test.exs`

This function reads the application config and upserts each entry using `name` as the conflict key. Fields that survive a conflict (not overwritten): `enabled`, `last_run_at`, `inserted_at`. Fields that are overwritten: everything else, including `next_run_at` which is set to `nil` so that `CronScheduler.initialize_null_next_run_ats/0` recomputes it (meaning a schedule change on the next boot takes effect immediately).

- [ ] **Step 1: Write the failing tests**

Open `test/distributed_task_queue_test.exs`. Add the following `describe` block. These tests must use `async: false` because they mutate global Application env — check the top of the file for `use DistributedTaskQueue.DataCase` and add `, async: false` if not already present for this describe. The safest approach is to put the tests in their own module at the bottom of the file:

```elixir
defmodule DistributedTaskQueue.UpsertCronJobsFromConfigTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{Repo, CronJob}

  @valid_entry %{
    name: "config-test-cron",
    worker_module: "MyApp.TestWorker",
    queue_name: "default",
    payload: %{},
    interval_seconds: 60
  }

  setup do
    on_exit(fn -> Application.delete_env(:distributed_task_queue, :cron_jobs) end)
    :ok
  end

  describe "upsert_cron_jobs_from_config/0" do
    test "inserts a new cron job from config" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.worker_module == "MyApp.TestWorker"
      assert cron.interval_seconds == 60
      assert is_nil(cron.next_run_at)
    end

    test "updates worker_module on conflict (name already exists)" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])
      DistributedTaskQueue.upsert_cron_jobs_from_config()

      updated_entry = Map.put(@valid_entry, :worker_module, "MyApp.UpdatedWorker")
      Application.put_env(:distributed_task_queue, :cron_jobs, [updated_entry])
      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert cron.worker_module == "MyApp.UpdatedWorker"
    end

    test "sets next_run_at to nil on conflict so it gets recomputed" do
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60,
             next_run_at: ~U[2099-01-01 00:00:00Z])
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      assert is_nil(cron.next_run_at)
    end

    test "preserves enabled flag on conflict" do
      insert(:cron_job, name: "config-test-cron", interval_seconds: 60, enabled: false)
      Application.put_env(:distributed_task_queue, :cron_jobs, [@valid_entry])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      cron = Repo.get_by(CronJob, name: "config-test-cron")
      refute cron.enabled
    end

    test "does nothing when config is empty" do
      Application.put_env(:distributed_task_queue, :cron_jobs, [])

      DistributedTaskQueue.upsert_cron_jobs_from_config()

      assert Repo.aggregate(CronJob, :count) == 0
    end

    test "returns error tuple for invalid config entry, does not raise" do
      bad_entry = %{name: "bad-cron"}
      Application.put_env(:distributed_task_queue, :cron_jobs, [bad_entry])

      results = DistributedTaskQueue.upsert_cron_jobs_from_config()

      assert [{:error, _changeset}] = results
    end
  end
end
```

- [ ] **Step 2: Run the tests and confirm they all fail**

```bash
mix test test/distributed_task_queue_test.exs --only "upsert_cron_jobs_from_config"
```

Expected: `UndefinedFunctionError` — `upsert_cron_jobs_from_config/0` doesn't exist yet.

- [ ] **Step 3: Add the function to the context**

In `lib/distributed_task_queue.ex`, add `require Logger` at the top of the module (after the `import Ecto.Query` line), then add this function after `disable_cron_job/1`:

```elixir
require Logger

def upsert_cron_jobs_from_config do
  Application.get_env(:distributed_task_queue, :cron_jobs, [])
  |> Enum.map(fn attrs ->
    changeset =
      %CronJob{}
      |> CronJob.changeset(Map.put(attrs, :next_run_at, nil))

    if changeset.valid? do
      Repo.insert(changeset,
        on_conflict:
          {:replace,
           [
             :worker_module,
             :queue_name,
             :cron_expression,
             :interval_seconds,
             :payload,
             :max_attempts,
             :overlap,
             :description,
             :next_run_at,
             :updated_at
           ]},
        conflict_target: :name
      )
    else
      Logger.error(
        "CronScheduler: invalid config entry #{inspect(attrs)}: #{inspect(changeset.errors)}"
      )

      {:error, changeset}
    end
  end)
end
```

Note: `require Logger` must be a top-level declaration in the module, not inside the function. Place it after `import Ecto.Query`.

- [ ] **Step 4: Run the tests**

```bash
mix test test/distributed_task_queue_test.exs --only "upsert_cron_jobs_from_config"
```

Expected: all 6 pass.

- [ ] **Step 5: Run full test suite to check for regressions**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue.ex test/distributed_task_queue_test.exs
git commit -m "feat: add upsert_cron_jobs_from_config/0 to context"
```

---

## Task 3: Wire Config Seeding into CronScheduler

**Files:**
- Modify: `lib/distributed_task_queue/cron_scheduler.ex`
- Test: `test/distributed_task_queue/cron_scheduler_test.exs`

`CronScheduler.init/1` should call `upsert_cron_jobs_from_config/0` before `initialize_null_next_run_ats/0`. Order matters: upsert first (creates rows with `next_run_at: nil`), then initialize fills in the `next_run_at` for any nil rows, then scheduling begins.

- [ ] **Step 1: Write the failing test**

Open `test/distributed_task_queue/cron_scheduler_test.exs` and add this test inside the existing `describe "start_link/1"` block:

```elixir
test "seeds cron jobs from application config on init" do
  Application.put_env(:distributed_task_queue, :cron_jobs, [
    %{
      name: "scheduler-init-test",
      worker_module: "MyApp.TestWorker",
      queue_name: "default",
      payload: %{},
      interval_seconds: 300
    }
  ])

  on_exit(fn -> Application.delete_env(:distributed_task_queue, :cron_jobs) end)

  DistributedTaskQueue.upsert_cron_jobs_from_config()

  cron = Repo.get_by(DistributedTaskQueue.CronJob, name: "scheduler-init-test")
  assert cron != nil
  assert cron.interval_seconds == 300
end
```

Note: this test calls `upsert_cron_jobs_from_config/0` directly rather than re-starting the supervisor (which is already running). The CronScheduler integration is verified transitively: Task 3 Step 3 wires the call, and this test verifies the seeding function itself works in the scheduler's test context.

- [ ] **Step 2: Run the test and confirm it passes** (it tests the function from Task 2, so it should pass now)

```bash
mix test test/distributed_task_queue/cron_scheduler_test.exs
```

Expected: all pass.

- [ ] **Step 3: Add the call to `CronScheduler.init/1`**

In `lib/distributed_task_queue/cron_scheduler.ex`, update `init/1`:

```elixir
@impl true
def init(_opts) do
  DistributedTaskQueue.upsert_cron_jobs_from_config()
  initialize_null_next_run_ats()
  schedule_next_poll()
  {:ok, %{}}
end
```

- [ ] **Step 4: Run the full test suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/distributed_task_queue/cron_scheduler.ex \
        test/distributed_task_queue/cron_scheduler_test.exs
git commit -m "feat: seed cron jobs from application config on CronScheduler init"
```

---

## Task 4: Add Config Entry to `config.exs`

**Files:**
- Modify: `config/config.exs`

Add the config key with an empty default and a comment showing the full format so users know what fields are available without reading source.

- [ ] **Step 1: Add the config block**

In `config/config.exs`, add the following block just before the `import_config "#{config_env()}.exs"` line at the bottom:

```elixir
# Cron jobs declared here are upserted into the database each time the application starts.
# The `name` field is the unique key — changing it creates a new row.
# Required: name, worker_module, queue_name, payload, and one of cron_expression or interval_seconds.
# Optional: max_attempts (default 3), overlap (default false), description.
# Removed entries are NOT auto-disabled — set enabled: false in the DB to stop them.
#
# Example:
#   config :distributed_task_queue, :cron_jobs, [
#     %{
#       name: "daily_report",
#       worker_module: "MyApp.DailyReportWorker",
#       queue_name: "default",
#       cron_expression: "0 9 * * *",
#       payload: %{}
#     },
#     %{
#       name: "cleanup",
#       worker_module: "MyApp.CleanupWorker",
#       queue_name: "low",
#       interval_seconds: 3600
#     }
#   ]
config :distributed_task_queue, :cron_jobs, []
```

- [ ] **Step 2: Confirm the app still compiles and tests pass**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add config/config.exs
git commit -m "config: add :cron_jobs key with format documentation"
```
