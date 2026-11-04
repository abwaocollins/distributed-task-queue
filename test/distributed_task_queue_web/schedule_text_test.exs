defmodule DistributedTaskQueueWeb.ScheduleTextTest do
  use ExUnit.Case, async: true

  alias DistributedTaskQueueWeb.ScheduleText

  defp cron(expr, zone \\ nil),
    do: %{cron_expression: expr, interval_seconds: nil, timezone: zone}

  test "interval schedules" do
    assert ScheduleText.describe(%{interval_seconds: 30}) == "Every 30 seconds"
    assert ScheduleText.describe(%{interval_seconds: 60}) == "Every minute"
    assert ScheduleText.describe(%{interval_seconds: 300}) == "Every 5 minutes"
    assert ScheduleText.describe(%{interval_seconds: 3600}) == "Every hour"
    assert ScheduleText.describe(%{interval_seconds: 7200}) == "Every 2 hours"
    assert ScheduleText.describe(%{interval_seconds: 90}) == "Every 90 seconds"
  end

  test "common cron shapes" do
    assert ScheduleText.describe(cron("0 2 * * *", "Africa/Nairobi")) ==
             "Every day at 02:00 (Africa/Nairobi)"

    assert ScheduleText.describe(cron("0 9 * * 1")) == "Every Monday at 09:00"
    assert ScheduleText.describe(cron("30 17 * * 1,3")) == "Every Monday and Wednesday at 17:30"
    assert ScheduleText.describe(cron("0 9 * * 7")) == "Every Sunday at 09:00"
    assert ScheduleText.describe(cron("*/15 * * * *")) == "Every 15 minutes"
    assert ScheduleText.describe(cron("* * * * *")) == "Every minute"
    assert ScheduleText.describe(cron("*/1 * * * *")) == "Every minute"
    assert ScheduleText.describe(cron("5 * * * *")) == "Every hour at :05"
    assert ScheduleText.describe(cron("0 0 1 * *")) == "On day 1 of every month at 00:00"
  end

  test "anything else falls back to the expression" do
    assert ScheduleText.describe(cron("5 4 * 2-6 1,3")) == "5 4 * 2-6 1,3"
    assert ScheduleText.describe(cron("0 9 * * 1-5")) == "0 9 * * 1-5"
  end
end
