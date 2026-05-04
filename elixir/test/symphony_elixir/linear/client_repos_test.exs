defmodule SymphonyElixir.Linear.ClientReposTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  test "extract_repos parses multiple GH PRs from attachments" do
    issue = %{
      "attachments" => %{
        "nodes" => [
          %{"url" => "https://github.com/me/symphony/pull/1"},
          %{"url" => "https://github.com/me/symphony-ui/pull/2"},
          %{"url" => "https://example.org/random"},
          %{"url" => "https://github.com/me/symphony/issues/3"}
        ]
      }
    }

    assert [
             %{
               name: "symphony",
               pr: %{url: "https://github.com/me/symphony/pull/1", merged: false, review: nil}
             },
             %{
               name: "symphony-ui",
               pr: %{url: "https://github.com/me/symphony-ui/pull/2", merged: false, review: nil}
             }
           ] = Client.extract_repos(issue)
  end

  test "extract_repos returns [] when no GH PR attachments" do
    assert Client.extract_repos(%{"attachments" => %{"nodes" => []}}) == []
    assert Client.extract_repos(%{}) == []
  end

  test "extract_repos deduplicates repeated PR URLs" do
    issue = %{
      "attachments" => %{
        "nodes" => [
          %{"url" => "https://github.com/me/symphony/pull/1"},
          %{"url" => "https://github.com/me/symphony/pull/1"}
        ]
      }
    }

    assert [%{name: "symphony"}] = Client.extract_repos(issue)
  end
end
