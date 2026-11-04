defmodule DistributedTaskQueue.Webhooks.SignatureTest do
  use ExUnit.Case, async: true

  alias DistributedTaskQueue.Webhooks.Signature

  test "header matches a known vector" do
    body = ~s({"a":1})
    unix = 1_700_000_000
    expected = :crypto.mac(:hmac, :sha256, "s", "#{unix}.#{body}") |> Base.encode16(case: :lower)

    assert Signature.header(body, "s", unix) == "t=#{unix},v1=#{expected}"
  end

  test "valid? accepts a fresh signature" do
    now = System.os_time(:second)
    assert Signature.valid?(Signature.header("b", "s", now), "b", "s")
  end

  test "valid? rejects a tampered body and an old timestamp" do
    now = System.os_time(:second)
    header = Signature.header("body", "s", now)

    refute Signature.valid?(header, "other", "s")
    refute Signature.valid?(header, "body", "wrong")

    old = Signature.header("body", "s", now - 400)
    refute Signature.valid?(old, "body", "s")
    assert Signature.valid?(old, "body", "s", 500)

    future = Signature.header("body", "s", now + 400)
    refute Signature.valid?(future, "body", "s")
  end

  test "valid? rejects malformed headers" do
    refute Signature.valid?("garbage", "b", "s")
    refute Signature.valid?("t=abc,v1=ff", "b", "s")
    refute Signature.valid?("t=1", "b", "s")
    refute Signature.valid?(nil, "b", "s")
  end
end
