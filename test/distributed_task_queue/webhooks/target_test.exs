defmodule DistributedTaskQueue.Webhooks.TargetTest do
  use ExUnit.Case, async: true

  alias DistributedTaskQueue.Webhooks.Target

  describe "check/2 with allow_private: false" do
    test "refuses loopback, private, link-local and metadata addresses" do
      for url <- [
            "http://localhost/",
            "http://[::1]/",
            "http://127.1/",
            "http://2130706433/",
            "http://10.0.0.5/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data",
            "http://[fc00::1]/",
            "http://0.0.0.0/"
          ] do
        assert Target.check(url, allow_private: false) == {:error, :private_address},
               "expected #{url} to be refused"
      end
    end

    test "accepts a public address" do
      assert Target.check("http://93.184.216.34/", allow_private: false) == :ok
    end

    test "refuses an unresolvable host" do
      assert Target.check("http://does-not-exist.invalid/", allow_private: false) ==
               {:error, :unresolvable}
    end
  end

  test "allow_private: true lets localhost through" do
    assert Target.check("http://localhost/", allow_private: true) == :ok
  end

  test "demo_receivers mode accepts only receiver URLs" do
    opts = [targets: :demo_receivers, allow_private: false]

    assert Target.check(Target.demo_receiver_url("warehouse"), opts) == :ok

    for url <- [
          Target.demo_receiver_url("nope"),
          "https://example.com/",
          Target.demo_receiver_url("warehouse") <> "/../x"
        ] do
      assert Target.check(url, opts) == {:error, :not_a_demo_receiver},
             "expected #{url} to be refused"
    end
  end
end
