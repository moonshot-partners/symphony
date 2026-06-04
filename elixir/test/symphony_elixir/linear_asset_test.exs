defmodule SymphonyElixir.LinearAssetTest do
  # async: false — the test swaps the module-global :linear_asset_fetcher env.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias SymphonyElixirWeb.ObservabilityApiController, as: Api

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_asset_fetcher) end)
    :ok
  end

  test "proxies a Linear upload, injecting auth, and streams the bytes back" do
    Application.put_env(:symphony_elixir, :linear_asset_fetcher, fn url ->
      send(self(), {:fetched, url})
      {:ok, %{body: "PNGBYTES", content_type: "image/png"}}
    end)

    conn = Api.linear_asset(build_conn(), %{"path" => ["ws-id", "dir-id", "file-id"]})

    # The proxy reassembles the uploads.linear.app URL from the path glob.
    assert_received {:fetched, "https://uploads.linear.app/ws-id/dir-id/file-id"}
    assert conn.status == 200
    assert conn.resp_body == "PNGBYTES"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
  end

  test "always targets the fixed uploads host and encodes segments" do
    Application.put_env(:symphony_elixir, :linear_asset_fetcher, fn url ->
      send(self(), {:fetched, url})
      {:ok, %{body: "X", content_type: "image/png"}}
    end)

    # A segment that looks like another origin is still just a path segment
    # under the hardcoded host, so the fetch can never be steered elsewhere.
    Api.linear_asset(build_conn(), %{"path" => ["evil.com", "a b", "x"]})

    assert_received {:fetched, url}
    assert String.starts_with?(url, "https://uploads.linear.app/")
    assert url == "https://uploads.linear.app/evil.com/a%20b/x"
  end

  test "returns 404 when the fetch fails (missing token, bad status, transport error)" do
    for failure <- [{:error, :missing_token}, {:error, {:http, 403}}, {:error, :timeout}] do
      Application.put_env(:symphony_elixir, :linear_asset_fetcher, fn _url -> failure end)
      conn = Api.linear_asset(build_conn(), %{"path" => ["x"]})
      assert conn.status == 404
    end
  end
end
