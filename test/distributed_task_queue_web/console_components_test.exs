defmodule DistributedTaskQueueWeb.ConsoleComponentsTest do
  use ExUnit.Case, async: true

  import DistributedTaskQueueWeb.ConsoleComponents, only: [delimit: 1]

  test "delimit/1 groups thousands" do
    assert delimit(0) == "0"
    assert delimit(999) == "999"
    assert delimit(1000) == "1,000"
    assert delimit(1_234_567) == "1,234,567"
    assert delimit(-12_345) == "-12,345"
  end
end
