defmodule SymphonyElixir.GitHubPrBodyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPrBody

  describe "pr_body/1 with injected fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_body_fn) end)
      :ok
    end

    test "returns nil when the issue has no PR urls (injected fn never runs)" do
      Application.put_env(:symphony_elixir, :pr_body_fn, fn _ ->
        raise "should not be called"
      end)

      assert GitHubPrBody.pr_body(%{repos: []}) == nil
      assert GitHubPrBody.pr_body(%{}) == nil
    end

    test "delegates to the injected fn when PR urls are present" do
      Application.put_env(:symphony_elixir, :pr_body_fn, fn _issue ->
        "## QA self-review\n\n- Result: PASS\n"
      end)

      issue = %{repos: [%{name: "fe-next-app", pr: %{url: "https://github.com/o/r/pull/1"}}]}
      assert GitHubPrBody.pr_body(issue) =~ "Result: PASS"
    end

    test "returns nil verbatim from injected fn" do
      Application.put_env(:symphony_elixir, :pr_body_fn, fn _ -> nil end)

      issue = %{repos: [%{name: "fe-next-app", pr: %{url: "https://github.com/o/r/pull/1"}}]}
      assert GitHubPrBody.pr_body(issue) == nil
    end
  end

  describe "default_pr_body/1 — without shelling out" do
    test "returns nil when a non-PR url slips through pr_urls" do
      # `pr_urls` happily extracts any string url; only `fetch_body` filters
      # by the github.com/.../pull/N regex. A non-matching url short-circuits
      # to nil without shelling out to `gh`.
      issue = %{repos: [%{name: "x", pr: %{url: "https://example.com/not-a-pr"}}]}
      assert GitHubPrBody.default_pr_body(issue) == nil
    end

    test "returns nil when the issue has no repos field" do
      assert GitHubPrBody.default_pr_body(%{}) == nil
    end

    test "returns nil when repos is not a list" do
      assert GitHubPrBody.default_pr_body(%{repos: nil}) == nil
    end

    test "returns nil when a repo entry has no pr url" do
      issue = %{repos: [%{name: "fe-next-app", pr: nil}, %{name: "schools-out"}]}
      assert GitHubPrBody.default_pr_body(issue) == nil
    end
  end
end
