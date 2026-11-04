defmodule DistributedTaskQueueWeb.AuthTest do
  # Changes application env, so it cannot run alongside other tests.
  use DistributedTaskQueueWeb.ConnCase, async: false

  alias DistributedTaskQueueWeb.ConsoleAuth

  defp put_env(key, value) do
    previous = Application.fetch_env(:distributed_task_queue, key)
    Application.put_env(:distributed_task_queue, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:distributed_task_queue, key, v)
        :error -> Application.delete_env(:distributed_task_queue, key)
      end
    end)
  end

  defp basic(conn, user, pass),
    do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth(user, pass))

  describe "API keys" do
    setup do
      put_env(:api_keys, ["key-one", "key-two"])
    end

    test "a request without a key is rejected", %{conn: conn} do
      conn = get(conn, ~p"/api/queues")
      assert json_response(conn, 401)["error"] =~ "API key"
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "a wrong key is rejected", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer nope") |> get(~p"/api/queues")
      assert json_response(conn, 401)
    end

    test "any configured key is accepted", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer key-two") |> get(~p"/api/queues")
      assert json_response(conn, 200)
    end

    test "an empty key list locks the API", %{conn: conn} do
      put_env(:api_keys, [])
      conn = conn |> put_req_header("authorization", "Bearer ") |> get(~p"/api/queues")
      assert json_response(conn, 401)
    end

    test "with no keys configured the API is open", %{conn: conn} do
      put_env(:api_keys, nil)
      assert json_response(get(conn, ~p"/api/queues"), 200)
    end
  end

  describe "console basic auth" do
    setup do
      put_env(:admin_auth, username: "admin", password: "s3cret")
    end

    test "the console asks for credentials", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "wrong credentials are rejected", %{conn: conn} do
      assert conn |> basic("admin", "wrong") |> get(~p"/") |> Map.fetch!(:status) == 401
    end

    test "right credentials open the console", %{conn: conn} do
      assert conn |> basic("admin", "s3cret") |> get(~p"/queues") |> html_response(200)
    end

    test "LiveDashboard sits behind the same credentials", %{conn: conn} do
      assert get(conn, "/admin/dashboard/home").status == 401

      assert conn
             |> basic("admin", "s3cret")
             |> get("/admin/dashboard/home")
             |> html_response(200)
    end

    # The socket is a separate connection the plug never sees; the session flag
    # set by the plug is the only proof the visitor authenticated.
    test "the LiveView mount refuses a session that never authenticated" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, _} = ConsoleAuth.on_mount(:default, %{}, %{}, socket)
      assert {:cont, _} = ConsoleAuth.on_mount(:default, %{}, %{"dtq_admin" => true}, socket)
    end
  end

  describe "public console mode" do
    setup do
      put_env(:admin_auth, :public_console)
    end

    test "the console is open but LiveDashboard is not", %{conn: conn} do
      assert conn |> get(~p"/queues") |> html_response(200)
      assert get(conn, "/admin/dashboard/home").status == 404
    end
  end
end
