defmodule SymphonyElixir.GitHubPrCriticalReviewTest do
  @moduledoc """
  Unit coverage for the pure surface of SymphonyElixir.GitHubPr's
  critical-review detector (SYM-16).

  The five fixtures in `critical_review_from_comments/3` are the contract:
    - critical-against-HEAD       → {:critical, ...}
    - critical-against-older-commit → :none  (stale review, predates current HEAD)
    - importants-only             → :none  (verdict is request_changes but 0 critical)
    - suggestions-only            → :none  (verdict is "comment", not request_changes)
    - no-review-yet               → :none  (no workflow-bot verdict comment present)

  `parse_critical_review_body/1` is the body-string boundary between the
  pr-review-toolkit output and the boolean Symphony acts on; every shape it
  can see is pinned down here.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPr

  describe "parse_critical_review_body/1" do
    test "returns {:request_changes, n, items} for verdict with critical issues" do
      body = """
      # claude-pr-review: request_changes

      ## Critical Issues (2)
      - silent-failure-hunter: `foo.ts:36` — bare catch swallows errors
      - pr-test-analyzer: `bar.ts:56` — missing AC#1 e2e coverage

      ## Important Issues (1)
      - type-design-analyzer: `baz.ts:43` — nullable pair

      ## Suggestions (0)

      ## Strengths
      - clean refactor
      """

      assert {:request_changes, 2, items} = GitHubPr.parse_critical_review_body(body)
      assert length(items) == 2
      assert Enum.any?(items, &String.contains?(&1, "silent-failure-hunter"))
      assert Enum.any?(items, &String.contains?(&1, "pr-test-analyzer"))
    end

    test "returns :none for request_changes verdict with 0 critical issues" do
      body = """
      # claude-pr-review: request_changes

      ## Critical Issues (0)

      ## Important Issues (5)
      - some: important
      """

      assert GitHubPr.parse_critical_review_body(body) == :none
    end

    test "returns :none for 'comment' verdict (suggestions only)" do
      body = """
      # claude-pr-review: comment

      ## Critical Issues (0)

      ## Important Issues (0)

      ## Suggestions (3)
      - minor nit
      """

      assert GitHubPr.parse_critical_review_body(body) == :none
    end

    test "returns :none for 'approve' verdict" do
      body = """
      # claude-pr-review: approve

      ## Strengths
      - all clean
      """

      assert GitHubPr.parse_critical_review_body(body) == :none
    end

    test "returns :none when verdict header is absent" do
      body = "some random PR comment without the verdict header"
      assert GitHubPr.parse_critical_review_body(body) == :none
    end

    test "returns :none for nil body" do
      assert GitHubPr.parse_critical_review_body(nil) == :none
    end

    test "returns :none for empty body" do
      assert GitHubPr.parse_critical_review_body("") == :none
    end
  end

  describe "critical_review_from_comments/3" do
    @head_sha "30422a3b239044561c73e9229dbc9a5a86651dfb"
    @head_committed_at ~U[2026-05-21 13:27:00Z]

    test "fixture 1: critical-against-HEAD → {:critical, ...}" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (5)
          - silent-failure-hunter: bare catch
          - silent-failure-hunter: another bare catch
          - pr-test-analyzer: missing e2e
          - pr-test-analyzer: missing unit
          - comment-analyzer: unverifiable claim

          ## Important Issues (7)
          """,
          # Posted 13:42, AFTER head_committed_at 13:27 — review is fresh.
          "created_at" => "2026-05-21T13:42:06Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      assert {:critical, %{count: 5, items: items, head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at)

      assert length(items) == 5
    end

    test "fixture 2: critical-against-older-commit → :none (stale review)" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (2)
          - foo: bar
          - baz: qux
          """,
          # Posted 12:00, BEFORE head_committed_at 13:27 — agent has pushed since.
          "created_at" => "2026-05-21T12:00:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      assert GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at) ==
               :none
    end

    test "fixture 3: importants-only → :none (zero critical)" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (0)

          ## Important Issues (3)
          - one
          - two
          - three
          """,
          "created_at" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      assert GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at) ==
               :none
    end

    test "fixture 4: suggestions-only → :none (verdict is 'comment')" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: comment

          ## Critical Issues (0)

          ## Suggestions (2)
          - small nit
          - cosmetic
          """,
          "created_at" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      assert GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at) ==
               :none
    end

    test "fixture 5: no-review-yet → :none" do
      comments = [
        %{
          "body" => "Random human comment",
          "created_at" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "someone"}
        }
      ]

      assert GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at) ==
               :none

      # Also: empty list.
      assert GitHubPr.critical_review_from_comments([], @head_sha, @head_committed_at) == :none
    end

    test "picks the most recent verdict comment when multiple are present" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (1)
          - old: stale
          """,
          "created_at" => "2026-05-21T13:30:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        },
        %{
          "body" => """
          # claude-pr-review: approve

          ## Strengths
          - all clean now
          """,
          "created_at" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      # Latest verdict is `approve` → :none, regardless of an earlier critical review.
      assert GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at) ==
               :none
    end

    test "ignores non-verdict comments mixed in" do
      comments = [
        %{
          "body" => "human chatter",
          "created_at" => "2026-05-21T13:43:00Z",
          "user" => %{"login" => "person"}
        },
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (1)
          - real: critical
          """,
          "created_at" => "2026-05-21T13:42:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      assert {:critical, %{count: 1, head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at)
    end

    test "detects request_changes when GitHub wraps the verdict body" do
      comments = [
        %{
          "body" => """
          Automated code review (claude-pr-review):

          # claude-pr-review: request_changes

          ## Critical Issues (2)
          - code-reviewer: real contract gap
          - pr-test-analyzer: missing mounted-path test

          ## Important Issues (1)
          - another finding
          """,
          "createdAt" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "github-actions"}
        }
      ]

      assert {:critical, %{count: 2, items: items, head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at)

      assert length(items) == 2
    end

    test "detects request_changes with review submittedAt timestamp" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (1)
          - silent-failure-hunter: review body verdict
          """,
          "submittedAt" => "2026-05-21T14:00:00Z",
          "author" => %{"login" => "github-actions"}
        }
      ]

      assert {:critical, %{count: 1, head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at)
    end

    test "nil head_committed_at treats every verdict as fresh (conservative fallback)" do
      comments = [
        %{
          "body" => """
          # claude-pr-review: request_changes

          ## Critical Issues (1)
          - foo: bar
          """,
          "created_at" => "2026-05-21T12:00:00Z",
          "user" => %{"login" => "github-actions[bot]"}
        }
      ]

      assert {:critical, %{count: 1, head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, nil)
    end
  end

  describe "critical_review_pending?/1 with injected fn" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_critical_review_fn) end)
      :ok
    end

    test "returns :none for issue with no repos" do
      Application.put_env(:symphony_elixir, :pr_critical_review_fn, fn _ ->
        raise "should not be called"
      end)

      assert GitHubPr.critical_review_pending?(%{repos: []}) == :none
    end

    test "delegates to the injected fn and returns its result" do
      verdict = {:critical, %{count: 3, items: ["a", "b", "c"], head_sha: "abc123"}}
      Application.put_env(:symphony_elixir, :pr_critical_review_fn, fn _issue -> verdict end)

      issue = %{
        repos: [%{name: "fe-next-app", pr: %{url: "https://github.com/org/repo/pull/1"}}]
      }

      assert GitHubPr.critical_review_pending?(issue) == verdict
    end

    test "returns :none when injected fn returns :none" do
      Application.put_env(:symphony_elixir, :pr_critical_review_fn, fn _ -> :none end)

      issue = %{
        repos: [%{name: "fe-next-app", pr: %{url: "https://github.com/org/repo/pull/1"}}]
      }

      assert GitHubPr.critical_review_pending?(issue) == :none
    end
  end
end
