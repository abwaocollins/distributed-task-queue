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
  use ExUnit.Case, async: true

  alias DistributedTaskQueue.Webhooks.Target

  # demo_receiver_url/1 is built from endpoint config, not Endpoint.url/0, so it
  # works for processes that start before the endpoint. These pin the builder to
  # what Phoenix would produce for each environment's config.
  test "dev/test config: http on the listening port" do
    assert Target.base_url(url: [host: "localhost"], http: [port: 4000]) ==
             "http://localhost:4000"
  end

  test "prod config: the public https URL, default port omitted" do
    config = [url: [host: "dtq.fly.dev", port: 443, scheme: "https"], http: [port: 8080]]
    assert Target.base_url(config) == "https://dtq.fly.dev"
  end

  test "a string port from the environment is accepted" do
    assert Target.base_url(url: [host: "h"], http: [port: "4001"]) == "http://h:4001"
  end
end
