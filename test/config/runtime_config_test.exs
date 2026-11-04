defmodule DistributedTaskQueue.RuntimeConfigTest do
  # Mutates the process environment, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  @moduletag :config

  @vars ~w(SECRET_KEY_BASE DATABASE_URL DTQ_PUBLIC_CONSOLE DTQ_API_KEYS DTQ_DEMO_API_KEY
           DTQ_WEBHOOK_SECRET DTQ_WEBHOOK_TARGETS DTQ_ADMIN_USERNAME DTQ_ADMIN_PASSWORD)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)

    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))
    System.put_env("DATABASE_URL", "ecto://u:p@localhost/db")
    System.put_env("DTQ_PUBLIC_CONSOLE", "true")
    System.put_env("DTQ_WEBHOOK_SECRET", "whsec")
    :ok
  end

  defp app_config do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod, target: :host)
    |> Keyword.fetch!(:distributed_task_queue)
  end

  test "raises without DTQ_WEBHOOK_SECRET" do
    System.delete_env("DTQ_WEBHOOK_SECRET")
    assert_raise RuntimeError, ~r/DTQ_WEBHOOK_SECRET/, &app_config/0
  end

  test "reads the secret, defaults to any target and refuses private ones" do
    webhooks = Keyword.fetch!(app_config(), :webhooks)

    assert webhooks[:secret] == "whsec"
    assert webhooks[:targets] == :any
    assert webhooks[:allow_private_targets] == false
  end

  test "DTQ_WEBHOOK_TARGETS=demo gives :demo_receivers" do
    System.put_env("DTQ_WEBHOOK_TARGETS", "demo")
    assert app_config()[:webhooks][:targets] == :demo_receivers
  end

  test "the demo key is added to api_keys and stored for the intro page" do
    System.put_env("DTQ_API_KEYS", "one, two")
    System.put_env("DTQ_DEMO_API_KEY", "demo-key")
    config = app_config()

    assert config[:api_keys] == ["one", "two", "demo-key"]
    assert config[:demo_api_key] == "demo-key"
  end

  test "without a demo key, api_keys is unchanged and no demo key is set" do
    System.put_env("DTQ_API_KEYS", "one")
    config = app_config()

    assert config[:api_keys] == ["one"]
    refute Keyword.has_key?(config, :demo_api_key)
  end
end
