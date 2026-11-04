defmodule DistributedTaskQueue.Webhooks.RequestTest do
  use ExUnit.Case, async: true

  alias DistributedTaskQueue.Webhooks.Request

  @masked "••••"

  describe "normalize/1" do
    test "defaults method to POST and timeout to 15_000" do
      assert {:ok, req} = Request.normalize(%{"url" => "https://example.com/hook"})
      assert req["method"] == "POST"
      assert req["timeout_ms"] == 15_000
      assert req["url"] == "https://example.com/hook"
      assert req["headers"] == %{}
      assert req["body"] == nil
    end

    test "accepts atom keys and upcases the method" do
      assert {:ok, req} = Request.normalize(%{url: "http://example.com", method: "put"})
      assert req["method"] == "PUT"
    end

    test "caps timeout_ms at 60_000" do
      assert {:ok, req} =
               Request.normalize(%{"url" => "https://example.com", "timeout_ms" => 999_999})

      assert req["timeout_ms"] == 60_000
    end

    test "rejects a bad timeout_ms" do
      for bad <- [0, -5, "abc", 1.5] do
        assert {:error, [{:timeout_ms, _}]} =
                 Request.normalize(%{"url" => "https://example.com", "timeout_ms" => bad})
      end
    end

    test "rejects a non-http(s) url" do
      for url <- ["ftp://x", "javascript:alert(1)", "not a url", ""] do
        assert {:error, [{:url, _} | _]} = Request.normalize(%{"url" => url})
      end
    end

    test "rejects a missing or non-string url" do
      assert {:error, [{:url, _} | _]} = Request.normalize(%{})
      assert {:error, [{:url, _} | _]} = Request.normalize(%{"url" => 5})
    end

    test "rejects unknown methods" do
      assert {:error, [{:method, _}]} =
               Request.normalize(%{"url" => "https://example.com", "method" => "TRACE"})
    end

    test "rejects non-string header values" do
      assert {:error, [{:headers, _}]} =
               Request.normalize(%{"url" => "https://example.com", "headers" => %{"x-n" => 1}})
    end

    test "rejects headers that are not a map" do
      assert {:error, [{:headers, _}]} =
               Request.normalize(%{"url" => "https://example.com", "headers" => ["a"]})
    end

    test "rejects header values with control characters" do
      for bad <- ["a\r\nX-Evil: 1", "a\nb", "a\rb", "a\0b", "a\x7Fb"] do
        assert {:error, [{:headers, _}]} =
                 Request.normalize(%{
                   "url" => "https://example.com",
                   "headers" => %{"x-a" => bad}
                 })
      end

      assert {:ok, _} =
               Request.normalize(%{
                 "url" => "https://example.com",
                 "headers" => %{"x-a" => "a	b"}
               })
    end

    test "rejects invalid header names" do
      for bad <- ["", "has space", "bad\nname", "colon:name"] do
        assert {:error, [{:headers, _}]} =
                 Request.normalize(%{"url" => "https://example.com", "headers" => %{bad => "v"}})
      end
    end

    test "rejects header names and values with a trailing newline" do
      for headers <- [%{"x-a
" => "v"}, %{"x-a
" => "v"}, %{"x-a" => "v
"}] do
        assert {:error, [{:headers, _}]} =
                 Request.normalize(%{"url" => "https://example.com", "headers" => headers})
      end
    end

    test "rejects header names that differ only by case" do
      assert {:error, [{:headers, _}]} =
               Request.normalize(%{
                 "url" => "https://example.com",
                 "headers" => %{"Accept" => "a", "accept" => "b"}
               })
    end

    test "returns an error instead of raising for an unencodable body" do
      assert {:error, [{:body, _}]} =
               Request.normalize(%{"url" => "https://example.com", "body" => %{"a" => {1, 2}}})
    end

    test "lowercases header names" do
      assert {:ok, req} =
               Request.normalize(%{
                 "url" => "https://example.com",
                 "headers" => %{"X-Trace" => "1"}
               })

      assert req["headers"] == %{"x-trace" => "1"}
    end

    test "JSON-encodes a map body and sets content-type" do
      assert {:ok, req} =
               Request.normalize(%{"url" => "https://example.com", "body" => %{"a" => 1}})

      assert Jason.decode!(req["body"]) == %{"a" => 1}
      assert req["headers"]["content-type"] == "application/json"
    end

    test "JSON-encodes a list body" do
      assert {:ok, req} = Request.normalize(%{"url" => "https://example.com", "body" => [1, 2]})
      assert req["body"] == "[1,2]"
      assert req["headers"]["content-type"] == "application/json"
    end

    test "keeps a caller content-type" do
      assert {:ok, req} =
               Request.normalize(%{
                 "url" => "https://example.com",
                 "headers" => %{"Content-Type" => "application/vnd.api+json"},
                 "body" => %{"a" => 1}
               })

      assert req["headers"]["content-type"] == "application/vnd.api+json"
    end

    test "passes a string body through without adding content-type" do
      assert {:ok, req} = Request.normalize(%{"url" => "https://example.com", "body" => "raw"})
      assert req["body"] == "raw"
      refute Map.has_key?(req["headers"], "content-type")
    end

    test "rejects a body of another type" do
      assert {:error, [{:body, _}]} =
               Request.normalize(%{"url" => "https://example.com", "body" => 42})
    end
  end

  describe "redact_headers/1" do
    test "redacts credential-like headers" do
      headers = %{
        "authorization" => "Bearer x",
        "X-Api-Key" => "k",
        "x-auth-token" => "t",
        "cookie" => "c=1",
        "my-secret" => "s",
        "accept" => "application/json"
      }

      redacted = Request.redact_headers(headers)

      for name <- ~w(authorization X-Api-Key x-auth-token cookie my-secret) do
        assert redacted[name] == @masked
      end

      assert redacted["accept"] == "application/json"
    end

    test "redacts signature headers but not look-alikes" do
      redacted =
        Request.redact_headers(%{
          "stripe-signature" => "s",
          "x-hub-signature-256" => "s",
          "proxy-authorization" => "p",
          "www-authenticate" => "Basic",
          "x-author" => "me"
        })

      assert redacted["stripe-signature"] == @masked
      assert redacted["x-hub-signature-256"] == @masked
      assert redacted["proxy-authorization"] == @masked
      assert redacted["www-authenticate"] == "Basic"
      assert redacted["x-author"] == "me"
    end

    test "masked/0 exposes the mask" do
      assert Request.masked() == @masked
    end
  end

  describe "merge_masked/2" do
    test "keeps the stored secret" do
      assert Request.merge_masked(
               %{"authorization" => @masked, "accept" => "b"},
               %{"authorization" => "Bearer real", "accept" => "a"}
             ) == %{"authorization" => "Bearer real", "accept" => "b"}
    end

    test "matches stored names case-insensitively" do
      assert Request.merge_masked(%{"Authorization" => @masked}, %{"authorization" => "real"}) ==
               %{"Authorization" => "real"}
    end

    test "leaves a masked value with no stored counterpart as is" do
      assert Request.merge_masked(%{"x-new" => @masked}, %{}) == %{"x-new" => @masked}
    end
  end
end
