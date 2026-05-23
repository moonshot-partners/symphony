defmodule SymphonyElixir.GitHubPrFilesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPrFiles

  describe "changed_files/1 with injected fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_changed_files_fn) end)
      :ok
    end

    test "returns [] when the issue has no PR urls (injected fn never runs)" do
      Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _ ->
        raise "should not be called"
      end)

      assert GitHubPrFiles.changed_files(%{repos: []}) == []
      assert GitHubPrFiles.changed_files(%{}) == []
    end

    test "delegates to the injected fn when PR urls are present" do
      Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _issue ->
        ["lib/foo.ex", "test/foo_test.exs"]
      end)

      issue = %{repos: [%{name: "schools-out", pr: %{url: "https://github.com/o/r/pull/1"}}]}
      assert GitHubPrFiles.changed_files(issue) == ["lib/foo.ex", "test/foo_test.exs"]
    end

    test "returns empty list verbatim from injected fn" do
      Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn _ -> [] end)

      issue = %{repos: [%{name: "schools-out", pr: %{url: "https://github.com/o/r/pull/1"}}]}
      assert GitHubPrFiles.changed_files(issue) == []
    end
  end

  describe "default_changed_files/1 — without shelling out" do
    test "returns [] when a non-PR url slips through pr_urls" do
      # `pr_urls` happily extracts any string url; only fetch_changed_files
      # filters by the github.com/.../pull/N regex. A non-matching url
      # short-circuits to [] without shelling out to `gh`.
      issue = %{repos: [%{name: "x", pr: %{url: "https://example.com/not-a-pr"}}]}
      assert GitHubPrFiles.default_changed_files(issue) == []
    end

    test "returns [] when the issue has no repos field" do
      assert GitHubPrFiles.default_changed_files(%{}) == []
    end
  end
end
