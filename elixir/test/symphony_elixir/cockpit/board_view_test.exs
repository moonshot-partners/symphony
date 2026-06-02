defmodule SymphonyElixir.Cockpit.BoardViewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Cockpit.BoardView
  alias SymphonyElixir.Linear.Issue

  defp tracker do
    %{
      active_states: ["Todo", "In Progress"],
      on_complete_state: "In Code Review",
      on_exhaust_state: "In Code Review",
      on_promote_state: "Promote to Staging",
      on_pr_merge_state: "Merged",
      on_reject_state: "On Hold",
      terminal_states: ["Done", "Cancelled"]
    }
  end

  describe "relevant_states/1" do
    test "collects, drops nil/empty, and dedups" do
      states =
        BoardView.relevant_states(%{
          active_states: ["Todo", "Todo"],
          on_complete_state: "In Code Review",
          on_exhaust_state: "In Code Review",
          on_promote_state: nil,
          on_pr_merge_state: "",
          on_reject_state: "On Hold",
          terminal_states: nil
        })

      assert states == ["Todo", "In Code Review", "On Hold"]
    end
  end

  describe "ci_candidates/2" do
    test "keeps non-terminal issues and drops terminal ones" do
      active = %Issue{identifier: "A", state: "In Progress"}
      review = %Issue{identifier: "B", state: "In Code Review"}
      done = %Issue{identifier: "C", state: "Done"}
      cancelled = %Issue{identifier: "D", state: "Cancelled"}

      kept = BoardView.ci_candidates([active, review, done, cancelled], tracker())
      assert Enum.map(kept, & &1.identifier) == ["A", "B"]
    end

    test "keeps everything when terminal_states is nil" do
      issues = [%Issue{identifier: "A", state: "Done"}]
      assert BoardView.ci_candidates(issues, %{terminal_states: nil}) == issues
    end
  end

  describe "assemble/4" do
    test "maps tracker states into the contract shape" do
      board = BoardView.assemble([], [], tracker())

      assert board["states"] == %{
               "active" => ["Todo", "In Progress"],
               "onComplete" => "In Code Review",
               "onExhaust" => "In Code Review",
               "onPromote" => "Promote to Staging",
               "onPrMerge" => "Merged",
               "onReject" => "On Hold",
               "terminal" => ["Done", "Cancelled"],
               "upNextExtra" => [],
               "doneExtra" => [],
               "inProgressExtra" => []
             }

      assert board["tickets"] == []
    end

    test "carries the cockpit display extras (up-next / done / in-progress) into the states map" do
      board =
        BoardView.assemble([], [], tracker(),
          extra_up_next: ["Backlog", "Groomed"],
          extra_done: ["Approved QA", "Recently released"],
          extra_in_progress: ["In Development"]
        )

      assert board["states"]["upNextExtra"] == ["Backlog", "Groomed"]
      assert board["states"]["doneExtra"] == ["Approved QA", "Recently released"]
      assert board["states"]["inProgressExtra"] == ["In Development"]
    end

    test "includes the issue description (capped), nil when blank" do
      with_desc = %Issue{identifier: "SODEV-20", title: "T", state: "Todo", description: "do the thing", repos: []}
      without = %Issue{identifier: "SODEV-21", title: "T2", state: "Todo", description: nil, repos: []}

      [a, b] = BoardView.assemble([with_desc, without], [], tracker())["tickets"]
      assert a["description"] == "do the thing"
      assert b["description"] == nil
    end

    test "maps an issue with a PR and an enriching ledger run" do
      issue = %Issue{
        identifier: "SODEV-1",
        title: "Fix search",
        state: "In Progress",
        url: "https://linear.app/x/issue/SODEV-1",
        repos: [%{name: "r", pr: %{url: "https://github.com/o/r/pull/642"}}],
        updated_at: "2026-05-30T00:00:00Z"
      }

      runs = [
        %{"turns" => 9},
        %{"ticket" => "SODEV-1", "turns" => 3, "langfuse_trace_id" => "abc", "outcome" => "pr_open"}
      ]

      [ticket] = BoardView.assemble([issue], runs, tracker(), trace_base: "https://lf/t/")["tickets"]

      assert ticket["id"] == "SODEV-1"
      assert ticket["title"] == "Fix search"
      assert ticket["state"] == "In Progress"
      assert ticket["url"] == "https://linear.app/x/issue/SODEV-1"

      assert ticket["pr"] == %{
               "number" => 642,
               "ci" => nil,
               "url" => "https://github.com/o/r/pull/642"
             }

      assert ticket["agent"]["turn"] == 3
      assert ticket["agent"]["status"] == "idle"
      assert ticket["agent"]["costUsd"] == nil
      assert ticket["agent"]["lastAction"] == "pr_open"
      assert ticket["traceUrl"] == "https://lf/t/abc"
      assert ticket["evidence"] == []
      assert ticket["updatedAt"] == "2026-05-30T00:00:00Z"
    end

    test "handles string-keyed repo PRs and a missing updated_at" do
      issue = %Issue{
        identifier: "SODEV-2",
        title: "T2",
        state: "Done",
        url: "u",
        repos: [%{"name" => "r", "pr" => %{"url" => "https://github.com/o/r/pull/7"}}],
        updated_at: nil
      }

      [ticket] = BoardView.assemble([issue], [], tracker())["tickets"]
      assert ticket["pr"]["number"] == 7
      assert ticket["updatedAt"] == ""
      assert ticket["agent"]["turn"] == nil
      assert ticket["traceUrl"] == nil
    end

    test "no PR when repos lack a pr url, are absent, or url has no number" do
      no_pr = %Issue{identifier: "A", repos: [%{name: "r"}]}
      nil_repos = %Issue{identifier: "B", repos: nil}
      no_number = %Issue{identifier: "C", repos: [%{pr: %{url: "https://x/pulls"}}]}

      tickets = BoardView.assemble([no_pr, nil_repos, no_number], [], tracker())["tickets"]
      assert Enum.at(tickets, 0)["pr"] == nil
      assert Enum.at(tickets, 1)["pr"] == nil
      assert Enum.at(tickets, 2)["pr"]["number"] == 0
    end

    test "fills pr.ci from the ci map keyed by PR url" do
      issue = %Issue{
        id: "u1",
        identifier: "SODEV-7",
        title: "T",
        state: "In Code Review",
        repos: [%{name: "r", pr: %{url: "https://github.com/o/r/pull/5"}}]
      }

      [ticket] =
        BoardView.assemble([issue], [], tracker(), ci: [{"https://github.com/o/r/pull/5", "passing"}])["tickets"]

      assert ticket["pr"]["ci"] == "passing"
    end

    test "maps stored QA evidence into gallery items + report keyed by internal id" do
      issue = %Issue{id: "uuid-9", identifier: "SODEV-11", title: "T", state: "In Code Review", repos: []}

      manifest = %{
        "items" => [
          %{"name" => "01 before.png", "kind" => "image"},
          %{"name" => "session.webm", "kind" => "video"}
        ],
        "report" => "- Result: PASS\n"
      }

      [ticket] =
        BoardView.assemble([issue], [], tracker(), evidence: [{"uuid-9", manifest}])["tickets"]

      assert ticket["report"] == "- Result: PASS\n"

      assert ticket["evidence"] == [
               %{
                 "id" => "uuid-9-0",
                 "kind" => "image",
                 "name" => "01 before.png",
                 "url" => "/api/evidence/uuid-9/01%20before.png"
               },
               %{
                 "id" => "uuid-9-1",
                 "kind" => "video",
                 "name" => "session.webm",
                 "url" => "/api/evidence/uuid-9/session.webm"
               }
             ]
    end

    test "no evidence manifest yields an empty gallery and a nil report" do
      issue = %Issue{id: "uuid-x", identifier: "SODEV-12", title: "T", state: "Todo", repos: []}

      [ticket] = BoardView.assemble([issue], [], tracker())["tickets"]
      assert ticket["evidence"] == []
      assert ticket["report"] == nil
    end

    test "maps the completion summary markdown keyed by internal id; nil when absent" do
      with_summary = %Issue{id: "uuid-s", identifier: "SODEV-13", title: "T", state: "In Code Review", repos: []}
      without = %Issue{id: "uuid-n", identifier: "SODEV-14", title: "T2", state: "Todo", repos: []}

      [a, b] =
        BoardView.assemble([with_summary, without], [], tracker(), summary: [{"uuid-s", "## Ready for review\n"}])["tickets"]

      assert a["summary"] == "## Ready for review\n"
      assert b["summary"] == nil
    end

    test "marks tickets whose internal id is in the running set" do
      running = %Issue{id: "uuid-1", identifier: "SODEV-9", title: "T", state: "In Development", repos: []}
      idle = %Issue{id: "uuid-2", identifier: "SODEV-10", title: "T2", state: "Scheduled", repos: []}

      [a, b] = BoardView.assemble([running, idle], [], tracker(), running: ["uuid-1"])["tickets"]
      assert a["agent"]["status"] == "running"
      assert b["agent"]["status"] == "idle"
    end

    test "withholds the stale ledger turn / outcome / trace while an agent is running" do
      issue = %Issue{
        id: "uuid-r",
        identifier: "SODEV-15",
        title: "T",
        state: "In Progress",
        repos: [],
        updated_at: "2026-05-30T00:00:00Z"
      }

      # The ledger row is the previous finished run; it must not leak onto the
      # card while the agent is running again (live data comes from /live).
      runs = [%{"ticket" => "SODEV-15", "turns" => 9, "langfuse_trace_id" => "old", "outcome" => "pr_open"}]

      [ticket] =
        BoardView.assemble([issue], runs, tracker(), running: ["uuid-r"], trace_base: "https://lf/t/")["tickets"]

      assert ticket["agent"]["status"] == "running"
      assert ticket["agent"]["turn"] == nil
      assert ticket["agent"]["lastAction"] == nil
      assert ticket["traceUrl"] == nil
    end

    test "still surfaces the ledger turn / outcome / trace once the agent is idle" do
      issue = %Issue{id: "uuid-i", identifier: "SODEV-16", title: "T", state: "In Code Review", repos: []}
      runs = [%{"ticket" => "SODEV-16", "turns" => 9, "langfuse_trace_id" => "abc", "outcome" => "pr_open"}]

      [ticket] = BoardView.assemble([issue], runs, tracker(), trace_base: "https://lf/t/")["tickets"]

      assert ticket["agent"]["status"] == "idle"
      assert ticket["agent"]["turn"] == 9
      assert ticket["agent"]["lastAction"] == "pr_open"
      assert ticket["traceUrl"] == "https://lf/t/abc"
    end

    test "ignores unusable ledger fields without fabricating data" do
      issue = %Issue{identifier: "SODEV-3", title: "T3", state: "On Hold", url: "u", repos: []}

      runs = [
        %{"ticket" => "SODEV-3", "turns" => "oops", "langfuse_trace_id" => "", "outcome" => 123}
      ]

      [ticket] = BoardView.assemble([issue], runs, tracker())["tickets"]
      assert ticket["agent"]["turn"] == nil
      assert ticket["agent"]["lastAction"] == nil
      assert ticket["traceUrl"] == nil
    end
  end
end
