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

    test "refuses CGNAT, link-local v6, embedded IPv4, multicast and reserved addresses" do
      for url <- [
            "http://172.16.0.1/",
            "http://100.64.0.1/",
            "http://[fe80::1]/",
            "http://[::ffff:127.0.0.1]/",
            # NAT64 for 169.254.169.254, the cloud metadata address.
            "http://[64:ff9b::a9fe:a9fe]/",
            "http://224.0.0.1/",
            "http://255.255.255.255/",
            "http://[ff02::1]/"
          ] do
        assert Target.check(url, targets: :any, allow_private: false) ==
                 {:error, :private_address},
               "expected #{url} to be refused"
      end
    end

    test "accepts addresses just outside the blocked ranges" do
      for url <- [
            "http://172.32.0.1/",
            "http://100.128.0.1/",
            "http://223.255.255.255/",
            # NAT64 for a public address.
            "http://[64:ff9b::5db8:d822]/"
          ] do
        assert Target.check(url, targets: :any, allow_private: false) == :ok,
               "expected #{url} to be accepted"
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

  test "demo_receiver_url/1 matches the running endpoint's URL" do
    assert Target.demo_receiver_url("email") ==
             DistributedTaskQueueWeb.Endpoint.url() <> "/demo/receivers/email"
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

defmodule DistributedTaskQueue.Webhooks.TargetBootTest do
  # Not async: it removes global state every endpoint call reads.
  use ExUnit.Case, async: false

  alias DistributedTaskQueue.Webhooks.Target

  test "demo_receiver_url/1 does not need the endpoint to be running" do
    # The endpoint's persistent term is what Endpoint.url/0 reads and what is
    # missing before the endpoint starts.
    key = {Phoenix.Endpoint, DistributedTaskQueueWeb.Endpoint}
    saved = :persistent_term.get(key)
    :persistent_term.erase(key)

    try do
      assert_raise RuntimeError, fn -> DistributedTaskQueueWeb.Endpoint.url() end

      assert Target.demo_receiver_url("email") =~
               ~r{\Ahttp://localhost:\d+/demo/receivers/email\z}
    after
      :persistent_term.put(key, saved)
    end
  end
end
