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

    test "returns false when only one of multiple attached PRs is ready" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn
        "https://github.com/org/repo/pull/1" -> true
        "https://github.com/org/repo/pull/2" -> false
      end)

      issue = %{
        repos: [
          %{name: "schools-out", pr: %{url: "https://github.com/org/repo/pull/1"}},
          %{name: "fe-next-app", pr: %{url: "https://github.com/org/repo/pull/2"}}
        ]
      }

      assert GitHubPr.ready?(issue) == false
    end

    test "checks every attached PR before returning true" do
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
      assert_receive {:checked, "https://github.com/org/repo/pull/2"}
    end
  end

  describe "parse_qa_blocked?/1" do
    test "returns true when body contains '- Result: BLOCKED'" do
      body = "## QA self-review\n\n- Result: BLOCKED\n\nsome more text"
      assert GitHubPr.parse_qa_blocked?(body) == true
    end

    test "returns false when body contains '- Result: PASS'" do
      body = "## QA self-review\n\n- Result: PASS\n\nsome more text"
      assert GitHubPr.parse_qa_blocked?(body) == false
    end

    test "returns false for empty string" do
      assert GitHubPr.parse_qa_blocked?("") == false
    end

    test "returns false when no Result line present" do
      body = "## Summary\n\n- Some change\n\n## Test Plan\n\n- [x] Done"
      assert GitHubPr.parse_qa_blocked?(body) == false
    end
  end

  describe "qa_blocked?/1 with injected fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_qa_blocked_fn) end)
      :ok
    end

    test "returns true when injected fn returns true" do
      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> true end)
      assert GitHubPr.qa_blocked?(%{repos: []}) == true
    end

    test "returns false when injected fn returns false" do
      Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn _issue -> false end)
      assert GitHubPr.qa_blocked?(%{repos: []}) == false
    end
  end

  describe "classify_status_check_rollup/1" do
    test "returns :all_green when every CheckRun is COMPLETED+SUCCESS" do
      list = [
        %{"__typename" => "CheckRun", "name" => "build", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        %{"__typename" => "CheckRun", "name" => "lint", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end

    test "treats NEUTRAL/SKIPPED/STALE conclusions as green" do
      list = [
        %{"__typename" => "CheckRun", "name" => "a", "status" => "COMPLETED", "conclusion" => "NEUTRAL"},
        %{"__typename" => "CheckRun", "name" => "b", "status" => "COMPLETED", "conclusion" => "SKIPPED"},
        %{"__typename" => "CheckRun", "name" => "c", "status" => "COMPLETED", "conclusion" => "STALE"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end

    test "returns {:red, names} when any CheckRun concluded FAILURE" do
      list = [
        %{"__typename" => "CheckRun", "name" => "build", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "FAILURE"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == {:red, ["qa-evidence"]}
    end

    test "collects every red check name in order" do
      list = [
        %{"__typename" => "CheckRun", "name" => "build", "status" => "COMPLETED", "conclusion" => "FAILURE"},
        %{"__typename" => "CheckRun", "name" => "lint", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        %{"__typename" => "CheckRun", "name" => "test", "status" => "COMPLETED", "conclusion" => "CANCELLED"},
        %{"__typename" => "CheckRun", "name" => "deploy", "status" => "COMPLETED", "conclusion" => "TIMED_OUT"},
        %{"__typename" => "CheckRun", "name" => "scan", "status" => "COMPLETED", "conclusion" => "ACTION_REQUIRED"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) ==
               {:red, ["build", "test", "deploy", "scan"]}
    end

    test "returns :pending when any CheckRun is not yet COMPLETED" do
      list = [
        %{"__typename" => "CheckRun", "name" => "build", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        %{"__typename" => "CheckRun", "name" => "deploy", "status" => "IN_PROGRESS", "conclusion" => nil}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :pending
    end

    test "red wins over pending in mixed rollups" do
      list = [
        %{"__typename" => "CheckRun", "name" => "build", "status" => "COMPLETED", "conclusion" => "FAILURE"},
        %{"__typename" => "CheckRun", "name" => "deploy", "status" => "QUEUED", "conclusion" => nil}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == {:red, ["build"]}
    end

    test "handles legacy StatusContext entries (state/context shape)" do
      list = [
        %{"__typename" => "StatusContext", "context" => "ci/circleci", "state" => "SUCCESS"},
        %{"__typename" => "StatusContext", "context" => "ci/jenkins", "state" => "FAILURE"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == {:red, ["ci/jenkins"]}
    end

    test "StatusContext PENDING is pending" do
      list = [
        %{"__typename" => "StatusContext", "context" => "ci/jenkins", "state" => "PENDING"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :pending
    end

    test "returns :all_green for an empty list (no checks configured)" do
      assert GitHubPr.ChecksClassifier.classify_status_check_rollup([]) == :all_green
    end
  end

  describe "classify_status_check_rollup/1 (SYM-35 latest-per-name dedup)" do
    test "3 qa-evidence attempts (FAILURE, FAILURE, SUCCESS) → :all_green" do
      list = [
        %{
          "__typename" => "CheckRun",
          "name" => "qa-evidence",
          "status" => "COMPLETED",
          "conclusion" => "FAILURE",
          "startedAt" => "2026-05-24T20:16:17Z"
        },
        %{
          "__typename" => "CheckRun",
          "name" => "qa-evidence",
          "status" => "COMPLETED",
          "conclusion" => "FAILURE",
          "startedAt" => "2026-05-24T20:16:17Z"
        },
        %{
          "__typename" => "CheckRun",
          "name" => "qa-evidence",
          "status" => "COMPLETED",
          "conclusion" => "SUCCESS",
          "startedAt" => "2026-05-24T20:18:33Z"
        }
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end

    test "review CANCELLED twice then IN_PROGRESS → :pending (latest is running)" do
      list = [
        %{
          "__typename" => "CheckRun",
          "name" => "review",
          "status" => "COMPLETED",
          "conclusion" => "CANCELLED",
          "startedAt" => "2026-05-24T20:16:14Z"
        },
        %{
          "__typename" => "CheckRun",
          "name" => "review",
          "status" => "COMPLETED",
          "conclusion" => "CANCELLED",
          "startedAt" => "2026-05-24T20:16:18Z"
        },
        %{
          "__typename" => "CheckRun",
          "name" => "review",
          "status" => "IN_PROGRESS",
          "conclusion" => nil,
          "startedAt" => "2026-05-24T20:18:48Z"
        }
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :pending
    end

    test "latest attempt FAILURE wins over earlier SUCCESS" do
      list = [
        %{
          "__typename" => "CheckRun",
          "name" => "build",
          "status" => "COMPLETED",
          "conclusion" => "SUCCESS",
          "startedAt" => "2026-05-24T20:10:00Z"
        },
        %{
          "__typename" => "CheckRun",
          "name" => "build",
          "status" => "COMPLETED",
          "conclusion" => "FAILURE",
          "startedAt" => "2026-05-24T20:20:00Z"
        }
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == {:red, ["build"]}
    end

    test "SODEV-824 PR #595 full rollup → :pending (latest review IN_PROGRESS, qa-evidence SUCCESS)" do
      list = [
        %{"__typename" => "CheckRun", "name" => "Lint", "status" => "COMPLETED", "conclusion" => "SUCCESS", "startedAt" => "2026-05-24T20:15:12Z"},
        %{"__typename" => "CheckRun", "name" => "review", "status" => "COMPLETED", "conclusion" => "CANCELLED", "startedAt" => "2026-05-24T20:16:14Z"},
        %{"__typename" => "CheckRun", "name" => "scope-discipline", "status" => "COMPLETED", "conclusion" => "SUCCESS", "startedAt" => "2026-05-24T20:16:17Z"},
        %{"__typename" => "CheckRun", "name" => "scope-discipline", "status" => "COMPLETED", "conclusion" => "SUCCESS", "startedAt" => "2026-05-24T20:16:17Z"},
        %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "FAILURE", "startedAt" => "2026-05-24T20:16:17Z"},
        %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "FAILURE", "startedAt" => "2026-05-24T20:16:17Z"},
        %{"__typename" => "CheckRun", "name" => "review", "status" => "COMPLETED", "conclusion" => "CANCELLED", "startedAt" => "2026-05-24T20:16:18Z"},
        %{"__typename" => "CheckRun", "name" => "Test", "status" => "COMPLETED", "conclusion" => "SUCCESS", "startedAt" => "2026-05-24T20:17:09Z"},
        %{"__typename" => "CheckRun", "name" => "scope-discipline", "status" => "COMPLETED", "conclusion" => "SUCCESS", "startedAt" => "2026-05-24T20:18:33Z"},
        %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "SUCCESS", "startedAt" => "2026-05-24T20:18:33Z"},
        %{"__typename" => "CheckRun", "name" => "deploy", "status" => "COMPLETED", "conclusion" => "SKIPPED", "startedAt" => "2026-05-24T20:18:47Z"},
        %{"__typename" => "CheckRun", "name" => "review", "status" => "IN_PROGRESS", "conclusion" => nil, "startedAt" => "2026-05-24T20:18:48Z"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :pending
    end

    test "entries without startedAt fall back to insertion order (last wins)" do
      list = [
        %{"__typename" => "CheckRun", "name" => "x", "status" => "COMPLETED", "conclusion" => "FAILURE"},
        %{"__typename" => "CheckRun", "name" => "x", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end

    test "StatusContext entries dedupe by context (last wins, no startedAt)" do
      list = [
        %{"__typename" => "StatusContext", "context" => "ci/jenkins", "state" => "FAILURE"},
        %{"__typename" => "StatusContext", "context" => "ci/jenkins", "state" => "SUCCESS"}
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end

    test "out-of-order rollup keeps the older entry when the latest comes first" do
      list = [
        %{
          "__typename" => "CheckRun",
          "name" => "qa-evidence",
          "status" => "COMPLETED",
          "conclusion" => "SUCCESS",
          "startedAt" => "2026-05-24T20:18:33Z"
        },
        %{
          "__typename" => "CheckRun",
          "name" => "qa-evidence",
          "status" => "COMPLETED",
          "conclusion" => "FAILURE",
          "startedAt" => "2026-05-24T20:16:17Z"
        }
      ]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end

    test "entries without name, status, or state fall through cleanly" do
      list = [%{"__typename" => "Unknown"}]

      assert GitHubPr.ChecksClassifier.classify_status_check_rollup(list) == :all_green
    end
  end

  describe "classify_pr_view_payload/1 (SODEV-824 closed-PR poison-pill fix)" do
    test "CLOSED PR with stale FAILURE checks reports :all_green" do
      payload = %{
        "state" => "CLOSED",
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "FAILURE"},
          %{"__typename" => "CheckRun", "name" => "review", "status" => "COMPLETED", "conclusion" => "CANCELLED"}
        ]
      }

      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(payload) == :all_green
    end

    test "MERGED PR with stale FAILURE checks reports :all_green" do
      payload = %{
        "state" => "MERGED",
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "FAILURE"}
        ]
      }

      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(payload) == :all_green
    end

    test "OPEN PR with red checks still classifies as red" do
      payload = %{
        "state" => "OPEN",
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "name" => "qa-evidence", "status" => "COMPLETED", "conclusion" => "FAILURE"}
        ]
      }

      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(payload) == {:red, ["qa-evidence"]}
    end

    test "OPEN PR with all-green checks classifies as :all_green" do
      payload = %{
        "state" => "OPEN",
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "name" => "build", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
        ]
      }

      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(payload) == :all_green
    end

    test "OPEN PR with pending check classifies as :pending" do
      payload = %{
        "state" => "OPEN",
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "name" => "deploy", "status" => "IN_PROGRESS", "conclusion" => nil}
        ]
      }

      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(payload) == :pending
    end

    test "payload without state falls back to rollup-only classification" do
      payload = %{
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "name" => "x", "status" => "COMPLETED", "conclusion" => "FAILURE"}
        ]
      }

      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(payload) == {:red, ["x"]}
    end

    test "malformed payload returns :all_green" do
      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(%{}) == :all_green
      assert GitHubPr.ChecksClassifier.classify_pr_view_payload(%{"state" => "OPEN"}) == :all_green
    end
  end

  describe "required_checks_status/1 with injected fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_required_checks_status_fn) end)
      :ok
    end

    test "returns :all_green for issue with no PR urls" do
      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _ ->
        raise "should not be called"
      end)

      assert GitHubPr.required_checks_status(%{repos: []}) == :all_green
    end

    test "delegates to the injected fn when PR urls are present" do
      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _issue ->
        {:red, ["qa-evidence"]}
      end)

      issue = %{repos: [%{name: "schools-out", pr: %{url: "https://github.com/o/r/pull/1"}}]}
      assert GitHubPr.required_checks_status(issue) == {:red, ["qa-evidence"]}
    end

    test "returns :pending verbatim from injected fn" do
      Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn _ -> :pending end)

      issue = %{repos: [%{name: "schools-out", pr: %{url: "https://github.com/o/r/pull/1"}}]}
      assert GitHubPr.required_checks_status(issue) == :pending
    end
  end
end
