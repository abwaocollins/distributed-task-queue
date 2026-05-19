# Cron Job Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `cron_jobs` table and `CronScheduler` GenServer so recurring schedules fire jobs into the existing queue pipeline.

**Architecture:** A new `cron_jobs` table stores recurring schedules (cron expression or fixed interval). A `CronScheduler` GenServer polls for due cron jobs, inserts a `jobs` row for each, then updates `last_run_at` and `next_run_at`. The existing `jobs` pipeline is unchanged; cron-spawned jobs carry a nullable `cron_job_id` FK back to their origin.

**Tech Stack:** Elixir/Phoenix, Ecto/Postgres, `crontab` hex package (cron expression parsing + next-run computation)

---

## File Map

| Action | Path | Purpose |
|---|---|---|
| Modify | `mix.exs` | Add `crontab` dep |
| Create | `priv/repo/migrations/20260519000001_create_cron_jobs.exs` | New table + check constraint + indexes |
| Create | `priv/repo/migrations/20260519000002_add_cron_job_id_to_jobs.exs` | FK column on `jobs` |
| Create | `lib/distributed_task_queue/models/cron_job.ex` | Ecto schema + changeset + `compute_next_run_at/1` |
| Modify | `lib/distributed_task_queue/models/job.ex` | Add `cron_job_id` field |
| Modify | `lib/distributed_task_queue.ex` | Add CronJob context functions + `put_next_run_at/1` helper |
| Create | `lib/distributed_task_queue/cron_scheduler.ex` | GenServer: poll, fire, update |
| Modify | `lib/distributed_task_queue/application.ex` | Add CronScheduler to supervision tree |
| Modify | `test/support/data_case.ex` | Add `errors_on/1` test helper |
| Modify | `test/support/factory.ex` | Add `cron_job_factory` |
| Create | `test/distributed_task_queue/cron_job_test.exs` | Changeset + context function tests |
| Create | `test/distributed_task_queue/cron_scheduler_test.exs` | Scheduler behaviour tests |

---

## Task 1: Add crontab dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add dependency**

In `mix.exs`, inside the `defp deps do` list, add after the `{:postgrex, ...}` line:

```elixir
{:crontab, "~> 1.1"},
```

- [ ] **Step 2: Fetch dependency**

Run: `mix deps.get`
Expected: `crontab` appears in the output with no errors.

- [ ] **Step 3: Verify compile**

Run: `mix compile`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add crontab dependency"
```

---

## Task 2: Create cron_jobs migration

**Files:**
- Create: `priv/repo/migrations/20260519000001_create_cron_jobs.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260519000001_create_cron_jobs.exs`:

```elixir
defmodule DistributedTaskQueue.Repo.Migrations.CreateCronJobs do
  use Ecto.Migration

  def change do
    create table(:cron_jobs) do
      add :name, :string, null: false
      add :description, :text
      add :worker_module, :string, null: false
      add :queue_name, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :max_attempts, :integer, null: false, default: 3
      add :cron_expression, :string
      add :interval_seconds, :integer
      add :overlap, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime

      timestamps()
    end

    create unique_index(:cron_jobs, [:name])
    create index(:cron_jobs, [:next_run_at, :enabled])

    create constraint(:cron_jobs, :schedule_xor,
      check: "num_nonnulls(cron_expression, interval_seconds) = 1"
    )
  end
end
```

- [ ] **Step 2: Run migration**

Run: `mix ecto.migrate`
Expected: `== Running 20260519000001 DistributedTaskQueue.Repo.Migrations.CreateCronJobs`

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/20260519000001_create_cron_jobs.exs
git commit -m "feat(db): add cron_jobs table"
```

---

## Task 3: Add cron_job_id to jobs migration

**Files:**
- Create: `priv/repo/migrations/20260519000002_add_cron_job_id_to_jobs.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260519000002_add_cron_job_id_to_jobs.exs`:

```elixir
defmodule DistributedTaskQueue.Repo.Migrations.AddCronJobIdToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :cron_job_id, references(:cron_jobs, on_delete: :nilify_all)
    end

    create index(:jobs, [:cron_job_id])
  end
end
```

- [ ] **Step 2: Run migration**

Run: `mix ecto.migrate`
Expected: `== Running 20260519000002 DistributedTaskQueue.Repo.Migrations.AddCronJobIdToJobs`

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/20260519000002_add_cron_job_id_to_jobs.exs
git commit -m "feat(db): add cron_job_id FK to jobs"
```

---

## Task 4: CronJob Ecto model (TDD)

**Files:**
- Modify: `test/support/data_case.ex`
- Modify: `test/support/factory.ex`
- Create: `lib/distributed_task_queue/models/cron_job.ex`
- Create: `test/distributed_task_queue/cron_job_test.exs`

- [ ] **Step 1: Add errors_on helper to DataCase**

In `test/support/data_case.ex`, add inside the `using do` block after `import DistributedTaskQueue.DataCase`:

```elixir
def errors_on(changeset) do
  Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end)
end
```

- [ ] **Step 2: Add cron_job_factory**

In `test/support/factory.ex`, add after the `job_factory` block:

```elixir
def cron_job_factory do
  queue = insert(:queue)
  %DistributedTaskQueue.CronJob{
    name: sequence(:name, &"cron-job-#{&1}"),
    worker_module: "DistributedTaskQueue.EmailWorker",
    queue_name: queue.name,
    payload: %{"to" => "test@example.com"},
    interval_seconds: 300,
    overlap: false,
    enabled: true,
    next_run_at: DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:second)
  }
end
```

- [ ] **Step 3: Write failing tests**

Create `test/distributed_task_queue/cron_job_test.exs`:

```elixir
defmodule DistributedTaskQueue.CronJobTest do
  use DistributedTaskQueue.DataCase, async: true

  alias DistributedTaskQueue.CronJob

  @valid_interval_attrs %{
    name: "send-digest",
    worker_module: "DistributedTaskQueue.EmailWorker",
    queue_name: "emails",
    payload: %{"type" => "digest"},
    interval_seconds: 300
  }

  @valid_cron_attrs %{
    name: "send-digest",
    worker_module: "DistributedTaskQueue.EmailWorker",
    queue_name: "emails",
    payload: %{"type" => "digest"},
    cron_expression: "0 9 * * 1"
  }

  describe "changeset/2 with interval_seconds" do
    test "valid attrs produce a valid changeset" do
      cs = CronJob.changeset(%CronJob{}, @valid_interval_attrs)
      assert cs.valid?
    end

    test "interval_seconds must be positive" do
      cs = CronJob.changeset(%CronJob{}, Map.put(@valid_interval_attrs, :interval_seconds, 0))
      refute cs.valid?
      assert errors_on(cs).interval_seconds != []
    end
  end

  describe "changeset/2 with cron_expression" do
    test "valid cron expression produces a valid changeset" do
      cs = CronJob.changeset(%CronJob{}, @valid_cron_attrs)
      assert cs.valid?
    end

    test "invalid cron expression format is rejected" do
      cs = CronJob.changeset(%CronJob{}, Map.put(@valid_cron_attrs, :cron_expression, "not-a-cron"))
      refute cs.valid?
      assert "is not a valid cron expression" in errors_on(cs).cron_expression
    end
  end

  describe "changeset/2 schedule mutual exclusion" do
    test "both schedule fields set is invalid" do
      attrs = Map.merge(@valid_interval_attrs, %{cron_expression: "* * * * *"})
      cs = CronJob.changeset(%CronJob{}, attrs)
      refute cs.valid?
      assert "only one of cron_expression or interval_seconds may be set" in errors_on(cs).cron_expression
    end

    test "neither schedule field set is invalid" do
      attrs = Map.drop(@valid_interval_attrs, [:interval_seconds])
      cs = CronJob.changeset(%CronJob{}, attrs)
      refute cs.valid?
      assert "either cron_expression or interval_seconds must be set" in errors_on(cs).cron_expression
    end
  end

  describe "changeset/2 required fields" do
    test "name is required" do
      cs = CronJob.changeset(%CronJob{}, Map.delete(@valid_interval_attrs, :name))
      refute cs.valid?
      assert errors_on(cs).name != []
    end

    test "worker_module is required" do
      cs = CronJob.changeset(%CronJob{}, Map.delete(@valid_interval_attrs, :worker_module))
      refute cs.valid?
      assert errors_on(cs).worker_module != []
    end

    test "queue_name is required" do
      cs = CronJob.changeset(%CronJob{}, Map.delete(@valid_interval_attrs, :queue_name))
      refute cs.valid?
      assert errors_on(cs).queue_name != []
    end
  end

  describe "compute_next_run_at/1" do
    test "interval: next_run_at is now + interval_seconds" do
      cron = %CronJob{interval_seconds: 300}
      before = DateTime.utc_now()
      result = CronJob.compute_next_run_at(cron)
      assert DateTime.diff(result, before, :second) in 299..301
    end

    test "cron expression: next_run_at is in the future" do
      cron = %CronJob{cron_expression: "* * * * *"}
      result = CronJob.compute_next_run_at(cron)
      assert DateTime.compare(result, DateTime.utc_now()) == :gt
    end
  end
end
```

- [ ] **Step 4: Run tests to confirm they fail**

Run: `mix test test/distributed_task_queue/cron_job_test.exs`
Expected: compile error — `CronJob` module does not exist.

- [ ] **Step 5: Implement CronJob schema**

Create `lib/distributed_task_queue/models/cron_job.ex`:

```elixir
defmodule DistributedTaskQueue.CronJob do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cron_jobs" do
    field :name, :string
    field :description, :string
    field :worker_module, :string
    field :queue_name, :string
    field :payload, :map, default: %{}
    field :max_attempts, :integer, default: 3
    field :cron_expression, :string
    field :interval_seconds, :integer
    field :overlap, :boolean, default: false
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime

    timestamps()
  end

  def changeset(cron_job, attrs) do
    cron_job
    |> cast(attrs, [
      :name, :description, :worker_module, :queue_name, :payload,
      :max_attempts, :cron_expression, :interval_seconds,
      :overlap, :enabled, :last_run_at, :next_run_at
    ])
    |> validate_required([:name, :worker_module, :queue_name, :payload])
    |> unique_constraint(:name)
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_schedule()
    |> validate_cron_expression()
  end

  def compute_next_run_at(%__MODULE__{interval_seconds: seconds}) when not is_nil(seconds) do
    DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)
  end

  def compute_next_run_at(%__MODULE__{cron_expression: expr}) when not is_nil(expr) do
    {:ok, cron} = Crontab.CronExpression.Parser.parse(expr)
    {:ok, naive_next} = Crontab.Scheduler.get_next_run_date(cron, NaiveDateTime.utc_now())
    DateTime.from_naive!(naive_next, "Etc/UTC")
  end

  defp validate_schedule(changeset) do
    cron_expr = get_field(changeset, :cron_expression)
    interval = get_field(changeset, :interval_seconds)

    cond do
      not is_nil(cron_expr) and not is_nil(interval) ->
        add_error(changeset, :cron_expression, "only one of cron_expression or interval_seconds may be set")
      is_nil(cron_expr) and is_nil(interval) ->
        add_error(changeset, :cron_expression, "either cron_expression or interval_seconds must be set")
      true ->
        changeset
    end
  end

  defp validate_cron_expression(changeset) do
    case get_field(changeset, :cron_expression) do
      nil -> changeset
      expr ->
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
        end
    end
  end
end
```

- [ ] **Step 6: Run tests to confirm they pass**

Run: `mix test test/distributed_task_queue/cron_job_test.exs`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/distributed_task_queue/models/cron_job.ex \
        test/distributed_task_queue/cron_job_test.exs \
        test/support/data_case.ex \
        test/support/factory.ex
git commit -m "feat: add CronJob schema with changeset validation"
```

---

## Task 5: Update Job model with cron_job_id

**Files:**
- Modify: `lib/distributed_task_queue/models/job.ex`

- [ ] **Step 1: Write failing test**

In `test/distributed_task_queue/cron_job_test.exs`, add a new describe block at the bottom:

```elixir
describe "Job changeset accepts cron_job_id" do
  test "cron_job_id is castable" do
    attrs = %{
      queue_name: "emails",
      worker_module: "DistributedTaskQueue.EmailWorker",
      payload: %{},
      cron_job_id: 42
    }
    cs = DistributedTaskQueue.Job.changeset(%DistributedTaskQueue.Job{}, attrs)
    assert Ecto.Changeset.get_change(cs, :cron_job_id) == 42
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `mix test test/distributed_task_queue/cron_job_test.exs`
Expected: the new test fails — `cron_job_id` not in the cast list.

- [ ] **Step 3: Add cron_job_id to Job schema**

In `lib/distributed_task_queue/models/job.ex`:

After `field(:attempted_by, :string)`, add:

```elixir
field(:cron_job_id, :integer)
```

In the `cast` call inside `changeset/2`, add `:cron_job_id` to the list of castable fields.

- [ ] **Step 4: Run test to confirm it passes**

Run: `mix test test/distributed_task_queue/cron_job_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/distributed_task_queue/models/job.ex \
        test/distributed_task_queue/cron_job_test.exs
git commit -m "feat: add cron_job_id field to Job schema"
```

---

## Task 6: Context functions for CronJob (TDD)

**Files:**
- Modify: `lib/distributed_task_queue.ex`
- Modify: `test/distributed_task_queue/cron_job_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/distributed_task_queue/cron_job_test.exs`:

```elixir
describe "create_cron_job/1" do
  test "inserts record and sets next_run_at for interval schedule" do
    attrs = %{
      name: "interval-cron",
      worker_module: "DistributedTaskQueue.EmailWorker",
      queue_name: "emails",
      payload: %{},
      interval_seconds: 60
    }
    assert {:ok, cron} = DistributedTaskQueue.create_cron_job(attrs)
    assert cron.name == "interval-cron"
    assert not is_nil(cron.next_run_at)
    assert DateTime.diff(cron.next_run_at, DateTime.utc_now(), :second) in 58..62
  end

  test "inserts record and sets next_run_at for cron expression" do
    attrs = %{
      name: "cron-expr-job",
      worker_module: "DistributedTaskQueue.EmailWorker",
      queue_name: "emails",
      payload: %{},
      cron_expression: "* * * * *"
    }
    assert {:ok, cron} = DistributedTaskQueue.create_cron_job(attrs)
    assert not is_nil(cron.next_run_at)
    assert DateTime.compare(cron.next_run_at, DateTime.utc_now()) == :gt
  end

  test "returns error changeset on invalid attrs" do
    assert {:error, cs} = DistributedTaskQueue.create_cron_job(%{})
    refute cs.valid?
  end
end

describe "list_cron_jobs/0" do
  test "returns all cron jobs" do
    insert(:cron_job)
    insert(:cron_job)
    assert length(DistributedTaskQueue.list_cron_jobs()) >= 2
  end
end

describe "get_cron_job/1" do
  test "returns cron job by id" do
    cron = insert(:cron_job)
    assert DistributedTaskQueue.get_cron_job(cron.id).id == cron.id
  end

  test "returns nil for unknown id" do
    assert is_nil(DistributedTaskQueue.get_cron_job(0))
  end
end

describe "update_cron_job/2" do
  test "updates allowed fields" do
    cron = insert(:cron_job)
    assert {:ok, updated} = DistributedTaskQueue.update_cron_job(cron, %{description: "new desc"})
    assert updated.description == "new desc"
  end

  test "recomputes next_run_at when interval_seconds changes" do
    cron = insert(:cron_job, interval_seconds: 300)
    assert {:ok, updated} = DistributedTaskQueue.update_cron_job(cron, %{interval_seconds: 600})
    assert DateTime.diff(updated.next_run_at, DateTime.utc_now(), :second) in 598..602
  end

  test "returns error on invalid attrs" do
    cron = insert(:cron_job)
    assert {:error, cs} = DistributedTaskQueue.update_cron_job(cron, %{interval_seconds: -1})
    refute cs.valid?
  end
end

describe "delete_cron_job/1" do
  test "deletes the record" do
    cron = insert(:cron_job)
    assert {:ok, _} = DistributedTaskQueue.delete_cron_job(cron)
    assert is_nil(DistributedTaskQueue.get_cron_job(cron.id))
  end
end

describe "enable_cron_job/1 and disable_cron_job/1" do
  test "disable sets enabled to false" do
    cron = insert(:cron_job, enabled: true)
    assert {:ok, updated} = DistributedTaskQueue.disable_cron_job(cron)
    refute updated.enabled
  end

  test "enable sets enabled to true" do
    cron = insert(:cron_job, enabled: false)
    assert {:ok, updated} = DistributedTaskQueue.enable_cron_job(cron)
    assert updated.enabled
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `mix test test/distributed_task_queue/cron_job_test.exs`
Expected: failures — functions not defined.

- [ ] **Step 3: Add context functions to distributed_task_queue.ex**

At the top of `lib/distributed_task_queue.ex`, update the alias line from:

```elixir
alias DistributedTaskQueue.{Job, Queue}
```

to:

```elixir
alias DistributedTaskQueue.{Job, Queue, CronJob}
```

Then append the following functions before the final `end`:

```elixir
def create_cron_job(attrs) do
  %CronJob{}
  |> CronJob.changeset(attrs)
  |> put_next_run_at()
  |> Repo.insert()
end

def list_cron_jobs, do: Repo.all(CronJob)

def get_cron_job(id), do: Repo.get(CronJob, id)

def update_cron_job(cron_job, attrs) do
  cron_job
  |> CronJob.changeset(attrs)
  |> put_next_run_at_if_schedule_changed()
  |> Repo.update()
end

def delete_cron_job(cron_job), do: Repo.delete(cron_job)

def enable_cron_job(cron_job) do
  cron_job |> CronJob.changeset(%{enabled: true}) |> Repo.update()
end

def disable_cron_job(cron_job) do
  cron_job |> CronJob.changeset(%{enabled: false}) |> Repo.update()
end

defp put_next_run_at(changeset) do
  if changeset.valid? do
    next_run_at = changeset |> Ecto.Changeset.apply_changes() |> CronJob.compute_next_run_at()
    Ecto.Changeset.put_change(changeset, :next_run_at, next_run_at)
  else
    changeset
  end
end

defp put_next_run_at_if_schedule_changed(changeset) do
  if Ecto.Changeset.changed?(changeset, :cron_expression) or
       Ecto.Changeset.changed?(changeset, :interval_seconds) do
    put_next_run_at(changeset)
  else
    changeset
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `mix test test/distributed_task_queue/cron_job_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `mix test`
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue.ex \
        test/distributed_task_queue/cron_job_test.exs
git commit -m "feat: add CronJob context functions"
```

---

## Task 7: CronScheduler GenServer (TDD)

**Files:**
- Create: `lib/distributed_task_queue/cron_scheduler.ex`
- Create: `test/distributed_task_queue/cron_scheduler_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/distributed_task_queue/cron_scheduler_test.exs`:

```elixir
defmodule DistributedTaskQueue.CronSchedulerTest do
  use DistributedTaskQueue.DataCase, async: false

  alias DistributedTaskQueue.{CronScheduler, Repo, Job}
  import Ecto.Query

  describe "fire_due_crons/0" do
    test "creates a job for a due enabled cron" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: true,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      jobs = Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)
      assert length(jobs) == 1
      assert hd(jobs).worker_module == cron.worker_module
      assert hd(jobs).queue_name == cron.queue_name
    end

    test "updates last_run_at and next_run_at after firing" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: true,
        interval_seconds: 120,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      updated = Repo.get!(DistributedTaskQueue.CronJob, cron.id)
      assert not is_nil(updated.last_run_at)
      assert DateTime.diff(updated.next_run_at, DateTime.utc_now(), :second) in 118..122
    end

    test "skips disabled cron jobs" do
      cron = insert(:cron_job,
        enabled: false,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      assert Repo.all(from j in Job, where: j.cron_job_id == ^cron.id) == []
    end

    test "skips future cron jobs" do
      cron = insert(:cron_job,
        enabled: true,
        next_run_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)
      )

      CronScheduler.fire_due_crons()

      assert Repo.all(from j in Job, where: j.cron_job_id == ^cron.id) == []
    end

    test "overlap=false: skips fire when a pending job already exists" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: false,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "pending")

      CronScheduler.fire_due_crons()

      assert length(Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)) == 1
    end

    test "overlap=false: skips fire when a started job already exists" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: false,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "started")

      CronScheduler.fire_due_crons()

      assert length(Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)) == 1
    end

    test "overlap=true: fires even when an active job exists" do
      cron = insert(:cron_job,
        enabled: true,
        overlap: true,
        next_run_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
      )
      insert(:job, queue_name: cron.queue_name, cron_job_id: cron.id, status: "started")

      CronScheduler.fire_due_crons()

      assert length(Repo.all(from j in Job, where: j.cron_job_id == ^cron.id)) == 2
    end
  end

  describe "start_link/1" do
    test "starts without error" do
      assert {:ok, _pid} = start_supervised(CronScheduler)
    end
  end
end
```

Also update the job factory in `test/support/factory.ex` to accept `cron_job_id`:

```elixir
def job_factory do
  queue = insert(:queue)
  %DistributedTaskQueue.Job{
    queue_name: queue.name,
    worker_module: "DistributedTaskQueue.EmailWorker",
    payload: %{"to" => "test@example.com"},
    status: "pending",
    max_attempts: 3,
    cron_job_id: nil
  }
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `mix test test/distributed_task_queue/cron_scheduler_test.exs`
Expected: compile error — `CronScheduler` module not found.

- [ ] **Step 3: Implement CronScheduler**

Create `lib/distributed_task_queue/cron_scheduler.ex`:

```elixir
defmodule DistributedTaskQueue.CronScheduler do
  use GenServer

  alias DistributedTaskQueue.{Repo, CronJob, Job}
  import Ecto.Query

  @fallback_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def fire_due_crons do
    now = DateTime.utc_now()

    Repo.all(
      from c in CronJob,
        where: c.enabled == true and not is_nil(c.next_run_at) and c.next_run_at <= ^now
    )
    |> Enum.each(&maybe_fire/1)
  end

  @impl true
  def init(_opts) do
    initialize_null_next_run_ats()
    schedule_next_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    fire_due_crons()
    schedule_next_poll()
    {:noreply, state}
  end

  defp maybe_fire(cron) do
    if cron.overlap or no_active_jobs?(cron.id) do
      {:ok, _job} =
        DistributedTaskQueue.add_job(cron.queue_name, %{
          "worker_module" => cron.worker_module,
          "payload" => cron.payload,
          "max_attempts" => cron.max_attempts,
          "cron_job_id" => cron.id
        })

      next_run_at = CronJob.compute_next_run_at(cron)

      cron
      |> CronJob.changeset(%{
        last_run_at: DateTime.utc_now() |> DateTime.truncate(:second),
        next_run_at: next_run_at
      })
      |> Repo.update!()
    end
  end

  defp no_active_jobs?(cron_id) do
    not Repo.exists?(
      from j in Job,
        where: j.cron_job_id == ^cron_id and j.status in ["pending", "started"]
    )
  end

  defp schedule_next_poll do
    Process.send_after(self(), :poll, next_poll_delay_ms())
  end

  defp next_poll_delay_ms do
    now = DateTime.utc_now()

    case Repo.one(
           from c in CronJob,
             where: c.enabled == true and not is_nil(c.next_run_at),
             order_by: [asc: c.next_run_at],
             limit: 1,
             select: c.next_run_at
         ) do
      nil -> @fallback_interval_ms
      next_run_at -> max(DateTime.diff(next_run_at, now, :millisecond), 0)
    end
  end

  defp initialize_null_next_run_ats do
    Repo.all(from c in CronJob, where: c.enabled == true and is_nil(c.next_run_at))
    |> Enum.each(fn cron ->
      next_run_at = CronJob.compute_next_run_at(cron)
      cron |> CronJob.changeset(%{next_run_at: next_run_at}) |> Repo.update!()
    end)
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `mix test test/distributed_task_queue/cron_scheduler_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/distributed_task_queue/cron_scheduler.ex \
        test/distributed_task_queue/cron_scheduler_test.exs \
        test/support/factory.ex
git commit -m "feat: add CronScheduler GenServer"
```

---

## Task 8: Add CronScheduler to supervision tree

**Files:**
- Modify: `lib/distributed_task_queue/application.ex`

- [ ] **Step 1: Add CronScheduler as a supervised child**

In `lib/distributed_task_queue/application.ex`, add `DistributedTaskQueue.CronScheduler` to the `children` list after `DistributedTaskQueue.QueueBootstrapper`:

```elixir
children = [
  DistributedTaskQueueWeb.Telemetry,
  DistributedTaskQueue.Repo,
  {DNSCluster, query: Application.get_env(:distributed_task_queue, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: DistributedTaskQueue.PubSub},
  {Finch, name: DistributedTaskQueue.Finch},
  {Registry, keys: :unique, name: DistributedTaskQueue.WorkerRegistry},
  DistributedTaskQueue.WorkerSupervisor,
  DistributedTaskQueue.QueueBootstrapper,
  DistributedTaskQueue.CronScheduler,
  DistributedTaskQueueWeb.Endpoint
]
```

- [ ] **Step 2: Verify application starts**

Run: `mix compile`
Expected: no errors.

- [ ] **Step 3: Run full test suite one final time**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/distributed_task_queue/application.ex
git commit -m "feat: add CronScheduler to supervision tree"
```
