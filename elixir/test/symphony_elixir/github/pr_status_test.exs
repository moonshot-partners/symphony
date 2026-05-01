defmodule SymphonyElixir.GitHub.PrStatusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.PrStatus

  defp stub_plug(body) do
    fn conn ->
      Req.Test.json(conn, body)
    end
  end

  test "fetch returns merged=false review=nil for an open non-draft PR" do
    plug = stub_plug(%{"merged" => false, "draft" => false})
    assert {:ok, %{merged: false, review: nil}} = PrStatus.fetch("me", "symphony", 1, plug: plug)
  end

  test "fetch returns merged=true review=nil when PR is merged" do
    plug = stub_plug(%{"merged" => true, "draft" => false})
    assert {:ok, %{merged: true, review: nil}} = PrStatus.fetch("me", "symphony", 1, plug: plug)
  end

  test "fetch returns review=draft for draft PRs" do
    plug = stub_plug(%{"merged" => false, "draft" => true})
    assert {:ok, %{merged: false, review: "draft"}} = PrStatus.fetch("me", "symphony", 1, plug: plug)
  end

  test "fetch returns {:error, {:http, status}} on non-200" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end
    assert {:error, {:http, 404}} = PrStatus.fetch("me", "missing", 1, plug: plug)
  end

  test "fetch_for_url parses owner/repo/number from a github PR url" do
    plug = stub_plug(%{"merged" => true, "draft" => false})

    assert {:ok, %{merged: true}} =
             PrStatus.fetch_for_url("https://github.com/me/symphony/pull/42", plug: plug)
  end

  test "fetch_for_url returns :invalid_url for non-PR urls" do
    assert {:error, :invalid_url} = PrStatus.fetch_for_url("https://example.org/foo")
  end
end
