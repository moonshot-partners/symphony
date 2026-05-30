defmodule SymphonyElixir.GitHubPrCriticalReviewTest do
  @moduledoc """
  Unit coverage for the pure surface of SymphonyElixir.GitHubPr's
  critical-review detector (SYM-16).

  The five fixtures in `critical_review_from_comments/3` are the contract:
    - critical-against-HEAD       → {:critical, ...}
    - critical-against-older-commit → :none  (stale review, predates current HEAD)
    - importants-only             → {:critical, ...}  (the verdict is still request_changes)
    - suggestions-only            → :none  (verdict is "comment", not request_changes)
    - no-review-yet               → :none  (no workflow-bot verdict comment present)

  `parse_critical_review_body/1` is the body-string boundary between the
  pr-review-toolkit output and the boolean Symphony acts on; every shape it
  can see is pinned down here.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPr
  alias SymphonyElixir.GitHubPr.ReviewVerdict

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

    test "returns {:request_changes, 0, []} for request_changes verdict with 0 critical issues" do
      body = """
      # claude-pr-review: request_changes

      ## Critical Issues (0)

      ## Important Issues (5)
      - some: important
      """

      assert GitHubPr.parse_critical_review_body(body) == {:request_changes, 0, []}
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

    test "returns {:request_changes, n, items} for scope-discipline FAIL comments" do
      body = """
      scope-discipline: FAIL - 3 violations

      - RULE 1 (x2): `Makefile` and `spec/models/vendor_spec.rb` are in the diff but absent from the AC-trace mapping table.
      - RULE 2 (x1): `Makefile` `test:` target is a drive-by change unrelated to any AC item.
      """

      assert {:request_changes, 3, items} = GitHubPr.parse_critical_review_body(body)
      assert length(items) == 2
      assert Enum.any?(items, &String.contains?(&1, "RULE 1"))
      assert Enum.any?(items, &String.contains?(&1, "RULE 2"))
    end

    test "returns :none for scope-discipline PASS comments" do
      assert GitHubPr.parse_critical_review_body("scope-discipline: PASS") == :none
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

    test "fixture 3: importants-only → {:critical, ...} because verdict is request_changes" do
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

      assert {:critical, %{count: 0, items: [], head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at)
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

    test "scope-discipline PASS after FAIL clears the alarm" do
      comments = [
        %{
          "body" => """
          scope-discipline: FAIL - 1 violation

          - RULE 2: drive-by Makefile change
          """,
          "created_at" => "2026-05-21T13:30:00Z",
          "user" => %{"login" => "claude[bot]"}
        },
        %{
          "body" => "scope-discipline: PASS",
          "created_at" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "claude[bot]"}
        }
      ]

      assert GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at) ==
               :none
    end

    test "fresh scope-discipline FAIL blocks the PR" do
      comments = [
        %{
          "body" => """
          scope-discipline: FAIL - 2 violations

          - RULE 1: missing AC mapping
          - RULE 2: drive-by change
          """,
          "created_at" => "2026-05-21T14:00:00Z",
          "user" => %{"login" => "claude[bot]"}
        }
      ]

      assert {:critical, %{count: 2, items: items, head_sha: @head_sha}} =
               GitHubPr.critical_review_from_comments(comments, @head_sha, @head_committed_at)

      assert length(items) == 2
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

  describe "critical_review_from_structured_verdict/2" do
    @head_sha "30422a3b239044561c73e9229dbc9a5a86651dfb"

    defp verdict(overrides) do
      Map.merge(
        %{
          "schema_version" => 1,
          "verdict" => "approve",
          "blocking" => false,
          "severity_counts" => %{"critical" => 0, "important" => 0, "nit" => 0, "suggestion" => 0},
          "findings" => [],
          "repository" => "schoolsoutapp/fe-next-app",
          "pr_url" => "https://github.com/schoolsoutapp/fe-next-app/pull/616",
          "pr_number" => 616,
          "head_sha" => @head_sha,
          "base_sha" => "base-sha",
          "workflow_run_id" => "123",
          "workflow_job_id" => "456",
          "source" => "claude-pr-review",
          "generated_at" => "2026-05-28T12:00:00Z"
        },
        overrides
      )
    end

    test "blocks request_changes from the structured verdict even when critical count is zero" do
      payload =
        verdict(%{
          "verdict" => "request_changes",
          "blocking" => true,
          "severity_counts" => %{"critical" => 0, "important" => 1},
          "findings" => [
            %{
              "agent" => "pr-test-analyzer",
              "severity" => "important",
              "blocking" => true,
              "file" => "src/app.ts",
              "line" => 42,
              "title" => "missing regression coverage"
            }
          ]
        })

      assert {:critical, %{count: 0, items: [item], head_sha: @head_sha}} =
               GitHubPr.critical_review_from_structured_verdict(payload, @head_sha)

      assert item =~ "pr-test-analyzer"
      assert item =~ "src/app.ts:42"
      assert item =~ "missing regression coverage"
    end

    test "does not block nit-only comment verdicts" do
      payload =
        verdict(%{
          "verdict" => "comment",
          "blocking" => false,
          "severity_counts" => %{"critical" => 0, "nit" => 2},
          "findings" => [
            %{"severity" => "nit", "blocking" => false, "title" => "rename local variable"}
          ]
        })

      assert GitHubPr.critical_review_from_structured_verdict(payload, @head_sha) == :none
    end

    test "treats stale artifact sha as unknown and blocking" do
      payload = verdict(%{"head_sha" => "older-sha"})

      assert {:critical, %{count: 0, items: [item], head_sha: @head_sha}} =
               GitHubPr.critical_review_from_structured_verdict(payload, @head_sha)

      assert item =~ "stale head_sha"
    end

    test "treats malformed artifacts as unknown and blocking" do
      assert {:critical, %{count: 0, items: [item], head_sha: @head_sha}} =
               GitHubPr.critical_review_from_structured_verdict(%{"verdict" => "approve"}, @head_sha)

      assert item =~ "missing schema_version"
    end

    test "treats approve with blocking findings as unknown and blocking" do
      payload =
        verdict(%{
          "verdict" => "approve",
          "blocking" => false,
          "findings" => [%{"blocking" => true, "title" => "inconsistent blocker"}]
        })

      assert {:critical, %{items: [item]}} =
               GitHubPr.critical_review_from_structured_verdict(payload, @head_sha)

      assert item =~ "contains blocking findings"
    end
  end

  describe "ReviewVerdict.evaluate/2 edge cases" do
    @head_sha "30422a3b239044561c73e9229dbc9a5a86651dfb"

    defp artifact(overrides) do
      Map.merge(
        %{
          "schema_version" => 1,
          "verdict" => "approve",
          "blocking" => false,
          "severity_counts" => %{"critical" => 0},
          "findings" => [],
          "head_sha" => @head_sha
        },
        overrides
      )
    end

    test "rejects non-object payloads" do
      assert ReviewVerdict.evaluate([], @head_sha) == {:unknown, "artifact is not a JSON object"}
    end

    test "rejects unsupported and missing schema versions" do
      assert ReviewVerdict.evaluate(artifact(%{"schema_version" => 2}), @head_sha) ==
               {:unknown, "unsupported schema_version"}

      assert ReviewVerdict.evaluate(Map.delete(artifact(%{}), "schema_version"), @head_sha) ==
               {:unknown, "missing schema_version"}
    end

    test "rejects missing head sha" do
      assert ReviewVerdict.evaluate(Map.delete(artifact(%{}), "head_sha"), @head_sha) ==
               {:unknown, "missing head_sha"}
    end

    test "rejects unsupported and missing verdicts" do
      assert ReviewVerdict.evaluate(artifact(%{"verdict" => "block"}), @head_sha) ==
               {:unknown, "unsupported verdict"}

      assert ReviewVerdict.evaluate(Map.delete(artifact(%{}), "verdict"), @head_sha) ==
               {:unknown, "missing verdict"}
    end

    test "rejects missing blocking, findings, and severity counts" do
      assert ReviewVerdict.evaluate(Map.delete(artifact(%{}), "blocking"), @head_sha) ==
               {:unknown, "missing blocking"}

      assert ReviewVerdict.evaluate(Map.delete(artifact(%{}), "findings"), @head_sha) ==
               {:unknown, "missing findings"}

      assert ReviewVerdict.evaluate(Map.delete(artifact(%{}), "severity_counts"), @head_sha) ==
               {:unknown, "missing severity_counts"}
    end

    test "treats unknown verdict as unknown" do
      assert ReviewVerdict.evaluate(artifact(%{"verdict" => "unknown"}), @head_sha) ==
               {:unknown, "verdict unknown"}
    end

    test "rejects request_changes without blocking signal" do
      payload = artifact(%{"verdict" => "request_changes", "blocking" => false})

      assert ReviewVerdict.evaluate(payload, @head_sha) ==
               {:unknown, "request_changes without blocking findings"}
    end

    test "uses blocking finding count when critical severity count is missing" do
      payload =
        artifact(%{
          "verdict" => "request_changes",
          "blocking" => true,
          "severity_counts" => %{},
          "findings" => [
            %{"blocking" => true, "agent" => "", "file" => "src/app.ts", "title" => ""},
            %{"blocking" => true, "agent" => "reviewer", "title" => "no location"}
          ]
        })

      assert {:blocking, %{count: 2, items: items, head_sha: @head_sha}} =
               ReviewVerdict.evaluate(payload, @head_sha)

      assert "claude-pr-review: src/app.ts: blocking finding" in items
      assert "reviewer: no location" in items
    end

    test "rejects approve or comment verdicts marked blocking" do
      assert ReviewVerdict.evaluate(artifact(%{"verdict" => "approve", "blocking" => true}), @head_sha) ==
               {:unknown, "approve verdict marked blocking"}

      assert ReviewVerdict.evaluate(artifact(%{"verdict" => "comment", "blocking" => true}), @head_sha) ==
               {:unknown, "comment verdict marked blocking"}
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

  describe "critical_review_pending?/1 — PR state guard (closed-PR re-engagement)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pr_head_meta_fn)
        Application.delete_env(:symphony_elixir, :pr_comments_fn)
        Application.delete_env(:symphony_elixir, :pr_review_verdict_artifact_fn)
      end)

      :ok
    end

    defp issue_with_pr(url), do: %{repos: [%{name: "fe-next-app", pr: %{url: url}}]}

    test "a CLOSED PR with a stale request_changes comment does not re-engage" do
      Application.put_env(:symphony_elixir, :pr_head_meta_fn, fn _, _, _, _ ->
        {:ok, "deadbeef", ~U[2026-05-15 12:00:00Z], "CLOSED"}
      end)

      # The state guard must short-circuit before any comment fetch. If it
      # does not, this raises and the test fails loudly.
      Application.put_env(:symphony_elixir, :pr_comments_fn, fn _, _, _, _ ->
        flunk("fetch_pr_comments must not run for a CLOSED PR")
      end)

      assert GitHubPr.critical_review_pending?(issue_with_pr("https://github.com/org/repo/pull/5")) ==
               :none
    end

    test "a MERGED PR does not re-engage" do
      Application.put_env(:symphony_elixir, :pr_head_meta_fn, fn _, _, _, _ ->
        {:ok, "deadbeef", ~U[2026-05-15 12:00:00Z], "MERGED"}
      end)

      assert GitHubPr.critical_review_pending?(issue_with_pr("https://github.com/org/repo/pull/6")) ==
               :none
    end

    test "an OPEN PR with a fresh request_changes comment still re-engages" do
      Application.put_env(:symphony_elixir, :pr_head_meta_fn, fn _, _, _, _ ->
        {:ok, "deadbeef", ~U[2026-05-15 12:00:00Z], "OPEN"}
      end)

      Application.put_env(:symphony_elixir, :pr_review_verdict_artifact_fn, fn _, _, _, _ ->
        :missing
      end)

      Application.put_env(:symphony_elixir, :pr_comments_fn, fn _, _, _, _ ->
        {:ok,
         [
           %{
             "body" => "# claude-pr-review: request_changes\n\n## Critical Issues (1)\n- silent-failure-hunter: `a.ts:1` — bare catch swallows errors\n",
             "created_at" => "2026-05-15T13:00:00Z"
           }
         ]}
      end)

      assert {:critical, info} =
               GitHubPr.critical_review_pending?(issue_with_pr("https://github.com/org/repo/pull/7"))

      assert info.pr_url == "https://github.com/org/repo/pull/7"
    end
  end
end
