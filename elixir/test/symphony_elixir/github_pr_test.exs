defmodule SymphonyElixir.GitHubPrTest do
  @moduledoc """
  Unit coverage for the pure surface of SymphonyElixir.GitHubPr.

  default_ready?/1 shells out to `gh` and is intentionally NOT tested here —
  shelling out is exercised end-to-end. parse_state/1 and ready_from_state?/2
  are the pure decision boundary between `gh` output and the boolean Symphony
  acts on, so every shape they can see is pinned down by a test.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPr

  describe "parse_state/1" do
    test "trims whitespace and newlines" do
      assert GitHubPr.parse_state("  OPEN  \n") == "OPEN"
    end

    test "passes known states through verbatim" do
      assert GitHubPr.parse_state("OPEN") == "OPEN"
      assert GitHubPr.parse_state("MERGED") == "MERGED"
      assert GitHubPr.parse_state("CLOSED") == "CLOSED"
    end

    test "passes unknown states through verbatim (caller decides)" do
      assert GitHubPr.parse_state("not-a-state") == "not-a-state"
      assert GitHubPr.parse_state("") == ""
    end
  end

  describe "ready_from_state?/2" do
    test "MERGED is ready regardless of checks" do
      assert GitHubPr.ready_from_state?("MERGED", true) == true
      assert GitHubPr.ready_from_state?("MERGED", false) == true
      assert GitHubPr.ready_from_state?("MERGED", fn -> raise "should not be called for MERGED" end) == true
    end

    test "OPEN with checks passing is ready" do
      assert GitHubPr.ready_from_state?("OPEN", true) == true
      assert GitHubPr.ready_from_state?("OPEN", fn -> true end) == true
    end

    test "OPEN with checks failing is NOT ready — the SODEV-765 CI-green gate" do
      assert GitHubPr.ready_from_state?("OPEN", false) == false
      assert GitHubPr.ready_from_state?("OPEN", fn -> false end) == false
    end

    test "CLOSED is NOT ready — guards the stale closed-not-merged PR shape" do
      assert GitHubPr.ready_from_state?("CLOSED", true) == false
      assert GitHubPr.ready_from_state?("CLOSED", false) == false
    end

    test "unknown states are NOT ready" do
      assert GitHubPr.ready_from_state?("_unknown", true) == false
      assert GitHubPr.ready_from_state?("DRAFT", true) == false
      assert GitHubPr.ready_from_state?("", true) == false
    end

    test "thunk for OPEN is only evaluated when state matches OPEN" do
      pid = self()

      thunk = fn ->
        send(pid, :evaluated)
        true
      end

      assert GitHubPr.ready_from_state?("MERGED", thunk) == true
      refute_receive :evaluated, 50

      assert GitHubPr.ready_from_state?("CLOSED", thunk) == false
      refute_receive :evaluated, 50

      assert GitHubPr.ready_from_state?("OPEN", thunk) == true
      assert_receive :evaluated
    end
  end

  describe "ready?/1 with injected check_fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_ready_fn) end)
      :ok
    end

    test "returns false for issue with no repos" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _ -> raise "should not be called" end)
      assert GitHubPr.ready?(%{repos: []}) == false
    end

    test "returns false when no repo has a pr url" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _ -> raise "should not be called" end)
      assert GitHubPr.ready?(%{repos: [%{name: "schools-out"}]}) == false
    end

    test "returns true when the only attached PR is ready" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _ -> true end)

      issue = %{
        repos: [%{name: "schools-out", pr: %{url: "https://github.com/org/repo/pull/1"}}]
      }

      assert GitHubPr.ready?(issue) == true
    end

    test "returns false when every attached PR is not ready (stale or CI failing)" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _ -> false end)

      issue = %{
        repos: [
          %{name: "schools-out", pr: %{url: "https://github.com/org/repo/pull/1"}},
          %{name: "fe-next-app", pr: %{url: "https://github.com/org/repo/pull/2"}}
        ]
      }

      assert GitHubPr.ready?(issue) == false
    end

    test "short-circuits on first ready PR" do
      pid = self()

      Application.put_env(:symphony_elixir, :pr_ready_fn, fn url ->
        send(pid, {:checked, url})
        true
      end)

      issue = %{
        repos: [
          %{name: "a", pr: %{url: "https://github.com/org/repo/pull/1"}},
          %{name: "b", pr: %{url: "https://github.com/org/repo/pull/2"}}
        ]
      }

      assert GitHubPr.ready?(issue) == true
      assert_receive {:checked, "https://github.com/org/repo/pull/1"}
      refute_receive {:checked, "https://github.com/org/repo/pull/2"}, 50
    end
  end
end
