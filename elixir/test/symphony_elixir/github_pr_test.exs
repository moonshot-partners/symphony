defmodule SymphonyElixir.GitHubPrTest do
  @moduledoc """
  Unit coverage for the pure surface of SymphonyElixir.GitHubPr.

  default_active?/1 shells out to `gh` and is intentionally NOT tested here —
  shelling out is exercised end-to-end. classify/1 is the decision boundary
  between `gh` output and the boolean Symphony acts on, so every shape it can
  see is pinned down by a test.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPr

  describe "classify/1" do
    test "OPEN with merged=false is active" do
      assert GitHubPr.classify("OPEN\tfalse") == true
    end

    test "OPEN with merged=true is active" do
      assert GitHubPr.classify("OPEN\ttrue") == true
    end

    test "MERGED (closed + merged=true) is active" do
      assert GitHubPr.classify("MERGED\ttrue") == true
    end

    test "CLOSED + merged=true is active (defensive: gh sometimes reports state=CLOSED on merged PRs)" do
      assert GitHubPr.classify("CLOSED\ttrue") == true
    end

    test "CLOSED + merged=false is NOT active — the stale PR shape that motivated SODEV-765" do
      assert GitHubPr.classify("CLOSED\tfalse") == false
    end

    test "single-field OPEN (no tab) is still active — state alone is enough" do
      assert GitHubPr.classify("OPEN") == true
    end

    test "single-field MERGED (no tab) is NOT active — needs merged=true second column to be trusted" do
      assert GitHubPr.classify("MERGED") == false
    end

    test "empty output is NOT active" do
      assert GitHubPr.classify("") == false
    end

    test "garbage output is NOT active" do
      assert GitHubPr.classify("not\tjson\textra") == false
    end
  end

  describe "any_active?/1 with injected check_fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_active_check_fn) end)
      :ok
    end

    test "returns false for issue with no repos" do
      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _ -> raise "should not be called" end)
      assert GitHubPr.any_active?(%{repos: []}) == false
    end

    test "returns false when no repo has a pr url" do
      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _ -> raise "should not be called" end)
      assert GitHubPr.any_active?(%{repos: [%{name: "schools-out"}]}) == false
    end

    test "returns true when the only attached PR is active" do
      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _ -> true end)

      issue = %{
        repos: [%{name: "schools-out", pr: %{url: "https://github.com/org/repo/pull/1"}}]
      }

      assert GitHubPr.any_active?(issue) == true
    end

    test "returns false when every attached PR is stale" do
      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn _ -> false end)

      issue = %{
        repos: [
          %{name: "schools-out", pr: %{url: "https://github.com/org/repo/pull/1"}},
          %{name: "fe-next-app", pr: %{url: "https://github.com/org/repo/pull/2"}}
        ]
      }

      assert GitHubPr.any_active?(issue) == false
    end

    test "short-circuits on first active PR" do
      pid = self()

      Application.put_env(:symphony_elixir, :pr_active_check_fn, fn url ->
        send(pid, {:checked, url})
        true
      end)

      issue = %{
        repos: [
          %{name: "a", pr: %{url: "https://github.com/org/repo/pull/1"}},
          %{name: "b", pr: %{url: "https://github.com/org/repo/pull/2"}}
        ]
      }

      assert GitHubPr.any_active?(issue) == true
      assert_receive {:checked, "https://github.com/org/repo/pull/1"}
      refute_receive {:checked, "https://github.com/org/repo/pull/2"}, 50
    end
  end
end
