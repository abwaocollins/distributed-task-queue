defmodule DistributedTaskQueueWeb.ScheduleText do
  @moduledoc """
  Describes a cron job's schedule in plain English for the console. Only the
  common shapes are spelled out; anything else shows the raw expression, which
  is always correct even when it is not friendly.
  """

  alias Crontab.CronExpression.Parser

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @spec describe(map) :: String.t()
  def describe(%{interval_seconds: seconds}) when is_integer(seconds), do: interval(seconds)

  def describe(%{cron_expression: expr} = cron) when is_binary(expr) do
    case Parser.parse(expr) do
      {:ok, parsed} ->
        case text(parsed) do
          nil -> expr
          text -> text <> zone(Map.get(cron, :timezone))
        end

      _ ->
        expr
    end
  end

  def describe(_), do: "Unscheduled"

  defp interval(1), do: "Every second"
  defp interval(s) when s < 60, do: "Every #{s} seconds"
  defp interval(60), do: "Every minute"
  defp interval(s) when s < 3600 and rem(s, 60) == 0, do: "Every #{div(s, 60)} minutes"
  defp interval(3600), do: "Every hour"
  defp interval(s) when rem(s, 3600) == 0, do: "Every #{div(s, 3600)} hours"
  defp interval(s), do: "Every #{s} seconds"

  # Matches the five-field shapes below; nil means "not a shape we describe".
  defp text(%{minute: [:*], hour: [:*], day: [:*], month: [:*], weekday: [:*]}),
    do: "Every minute"

  defp text(%{minute: [{:/, :*, n}], hour: [:*], day: [:*], month: [:*], weekday: [:*]}),
    do: "Every #{n} minutes"

  defp text(%{minute: [m], hour: [:*], day: [:*], month: [:*], weekday: [:*]}) when is_integer(m),
    do: "Every hour at :" <> pad(m)

  defp text(%{minute: [m], hour: [h], day: [:*], month: [:*], weekday: [:*]})
       when is_integer(m) and is_integer(h),
       do: "Every day at #{clock(h, m)}"

  defp text(%{minute: [m], hour: [h], day: [:*], month: [:*], weekday: days})
       when is_integer(m) and is_integer(h) and days != [:*] do
    if Enum.all?(days, &(is_integer(&1) and &1 in 0..7)),
      do:
        "Every #{days |> Enum.map(&weekday/1) |> Enum.uniq() |> to_sentence()} at #{clock(h, m)}"
  end

  defp text(%{minute: [m], hour: [h], day: [d], month: [:*], weekday: [:*]})
       when is_integer(m) and is_integer(h) and is_integer(d),
       do: "On day #{d} of every month at #{clock(h, m)}"

  defp text(_), do: nil

  # Cron treats both 0 and 7 as Sunday.
  defp weekday(n), do: Enum.at(@weekdays, rem(n + 6, 7))

  defp to_sentence([one]), do: one
  defp to_sentence(list), do: Enum.join(Enum.drop(list, -1), ", ") <> " and " <> List.last(list)

  defp clock(h, m), do: pad(h) <> ":" <> pad(m)
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp zone(zone) when zone in [nil, ""], do: ""
  defp zone(zone), do: " (#{zone})"
end
