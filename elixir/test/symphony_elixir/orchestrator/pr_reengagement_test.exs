defmodule SymphonyElixir.Orchestrator.PrReengagementTest do
  @moduledoc """
  Unit coverage for the SYM-16 auto re-engagement loop.

  `PrReengagement.run/2` walks `state.completed`, asks the injected
  detector whether each issue's PR carries a fresh critical review, and
  either:

    * DISPATCH (count == 0) — increments `state.pr_engagements[pr_url].count`,
      removes the id from `state.completed`, transitions the issue back to
      the configured `on_pickup_state` so DispatchGate picks it up on the
      next tick, and posts a threaded workpad comment.

    * CAP-HIT (count >= 1, new head_sha) — transitions to
      `on_reject_state`, posts a threaded cap-hit comment, and records
      the head_sha in `cap_hit_shas` so the same sha never produces a
      second cap-hit comment.

    * CAP-HIT DEDUP (count >= 1, head_sha already in cap_hit_shas) —
      no state transition, no comment. Idempotent across poll cycles.

  Detector and side-effects are injected through `opts`. No GenServer,
  no Tracker, no GitHub network in this file.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{PrReengagement, State}

  defp build_state(completed_issues, pr_engagements \\ %{}) do
    %State{
      running: %{},
      claimed: MapSet.new(),
      completed: MapSet.new(Map.keys(completed_issues)),
      workpads:
        completed_issues
        |> Map.new(fn {issue_id, _issue} -> {issue_id, "wp-#{issue_id}"} end),
      retry_attempts: %{},
      pr_engagements: pr_engagements,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(id, pr_url) do
    %Issue{
      id: id,
      identifier: "ISS-#{id}",
      state: "Done",
      repos: [%{name: "fe-next-app", pr: %{url: pr_url}}]
    }
  end

  defp opts(extra) do
    Map.merge(
      %{
        pickup_state: "Scheduled",
        reject_state: "On Hold / Blocked"
      },
      extra
    )
  end

  describe "run/2" do
    test "no-op when state.completed is empty" do
      state = build_state(%{})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> raise "should not be called" end,
          detector_fn: fn _issue -> raise "should not be called" end,
          state_transition_fn: fn _issue, _target -> raise "should not be called" end,
          comment_fn: fn _id, _body, _parent -> raise "should not be called" end
        })

      assert PrReengagement.run(state, opts) == state
    end

    test "no-op when detector returns :none for every completed issue" do
      parent = self()

      completed = %{
        "i-1" => issue("i-1", "https://github.com/org/repo/pull/1"),
        "i-2" => issue("i-2", "https://github.com/org/repo/pull/2")
      }

      state = build_state(completed)

      opts =
        opts(%{
          issue_fetch_fn: fn ids ->
            send(parent, {:fetched, ids})
            {:ok, Enum.map(ids, &Map.fetch!(completed, &1))}
          end,
          detector_fn: fn _issue -> :none end,
          state_transition_fn: fn _issue, _target ->
            send(parent, :transitioned)
            :ok
          end,
          comment_fn: fn _id, _body, _parent ->
            send(parent, :commented)
            {:ok, "c-1"}
          end
        })

      assert ^state = PrReengagement.run(state, opts)

      assert_receive {:fetched, _ids}, 500
      refute_receive :transitioned, 50
      refute_receive :commented, 50
    end

    test "DISPATCH (count == 0): increments counter, removes from completed, transitions to pickup, posts threaded workpad comment" do
      parent = self()
      pr_url = "https://github.com/org/repo/pull/77"

      issue = issue("i-77", pr_url)
      state = build_state(%{"i-77" => issue})

      verdict =
        {:critical,
         %{
           count: 3,
           items: ["a", "b", "c"],
           head_sha: "deadbeefcafe1234",
           pr_url: pr_url
         }}

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [issue]} end,
          detector_fn: fn ^issue -> verdict end,
          state_transition_fn: fn ^issue, target ->
            send(parent, {:transitioned, target})
            :ok
          end,
          comment_fn: fn issue_id, body, parent_id ->
            send(parent, {:commented, issue_id, body, parent_id})
            {:ok, "c-77"}
          end
        })

      new_state = PrReengagement.run(state, opts)

      # state.pr_engagements counter incremented to 1.
      assert %{count: 1, cap_hit_shas: shas} = new_state.pr_engagements[pr_url]
      assert MapSet.size(shas) == 0

      # state.completed no longer holds the issue.
      refute MapSet.member?(new_state.completed, "i-77")

      # Linear transition to pickup state.
      assert_receive {:transitioned, "Scheduled"}, 500

      # Threaded workpad comment posted with the critical-issue summary.
      assert_receive {:commented, "i-77", body, "wp-i-77"}, 500
      assert body =~ "claude-pr-review" or body =~ "critical"
      assert body =~ "3"
    end

    test "CAP-HIT (count >= 1, new sha): transitions to reject state, posts cap-hit comment, records sha" do
      parent = self()
      pr_url = "https://github.com/org/repo/pull/77"

      issue = issue("i-77", pr_url)

      state =
        build_state(
          %{"i-77" => issue},
          %{pr_url => %{count: 1, cap_hit_shas: MapSet.new()}}
        )

      verdict =
        {:critical,
         %{
           count: 2,
           items: ["d", "e"],
           head_sha: "newsha456",
           pr_url: pr_url
         }}

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [issue]} end,
          detector_fn: fn ^issue -> verdict end,
          state_transition_fn: fn ^issue, target ->
            send(parent, {:transitioned, target})
            :ok
          end,
          comment_fn: fn issue_id, body, parent_id ->
            send(parent, {:commented, issue_id, body, parent_id})
            {:ok, "c-cap-1"}
          end
        })

      new_state = PrReengagement.run(state, opts)

      # Counter unchanged (still 1) but sha is now recorded.
      assert %{count: 1, cap_hit_shas: shas} = new_state.pr_engagements[pr_url]
      assert MapSet.member?(shas, "newsha456")

      # Issue stays in completed; we're parking it for human review.
      assert MapSet.member?(new_state.completed, "i-77")

      # Linear transition to reject state.
      assert_receive {:transitioned, "On Hold / Blocked"}, 500

      # Threaded cap-hit comment.
      assert_receive {:commented, "i-77", body, "wp-i-77"}, 500
      assert body =~ "K=1" or body =~ "cap"
      assert body =~ "newsha456" or body =~ "human"
    end

    test "CAP-HIT DEDUP (count >= 1, sha already recorded): no transition, no comment" do
      parent = self()
      pr_url = "https://github.com/org/repo/pull/77"

      issue = issue("i-77", pr_url)

      state =
        build_state(
          %{"i-77" => issue},
          %{
            pr_url => %{
              count: 1,
              cap_hit_shas: MapSet.new(["already-seen-sha"])
            }
          }
        )

      verdict =
        {:critical,
         %{
           count: 1,
           items: ["f"],
           head_sha: "already-seen-sha",
           pr_url: pr_url
         }}

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [issue]} end,
          detector_fn: fn ^issue -> verdict end,
          state_transition_fn: fn _issue, _target ->
            send(parent, :transitioned)
            :ok
          end,
          comment_fn: fn _id, _body, _parent ->
            send(parent, :commented)
            {:ok, "c-dup"}
          end
        })

      new_state = PrReengagement.run(state, opts)

      # State unchanged: same engagements, issue stays in completed.
      assert new_state.pr_engagements == state.pr_engagements
      assert MapSet.member?(new_state.completed, "i-77")

      refute_receive :transitioned, 50
      refute_receive :commented, 50
    end

    test "no-op when fetched issue has no PR url (defensive)" do
      parent = self()

      issue_no_pr = %Issue{
        id: "i-no-pr",
        identifier: "ISS-NOPR",
        state: "Done",
        repos: []
      }

      state = build_state(%{"i-no-pr" => issue_no_pr})

      # Detector should not even be called for an issue with no PR urls.
      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [issue_no_pr]} end,
          detector_fn: fn _issue ->
            send(parent, :detector_called)
            :none
          end,
          state_transition_fn: fn _issue, _target ->
            send(parent, :transitioned)
            :ok
          end,
          comment_fn: fn _id, _body, _parent ->
            send(parent, :commented)
            {:ok, "c"}
          end
        })

      assert ^state = PrReengagement.run(state, opts)

      refute_receive :detector_called, 50
      refute_receive :transitioned, 50
      refute_receive :commented, 50
    end

    test "no-op when issue_fetch_fn returns :error (preserves state, no exception)" do
      parent = self()
      pr_url = "https://github.com/org/repo/pull/1"

      state = build_state(%{"i-1" => issue("i-1", pr_url)})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:error, :network_glitch} end,
          detector_fn: fn _issue ->
            send(parent, :detector_called)
            :none
          end,
          state_transition_fn: fn _issue, _target ->
            send(parent, :transitioned)
            :ok
          end,
          comment_fn: fn _id, _body, _parent ->
            send(parent, :commented)
            {:ok, "c"}
          end
        })

      assert ^state = PrReengagement.run(state, opts)

      refute_receive :detector_called, 50
      refute_receive :transitioned, 50
      refute_receive :commented, 50
    end
  end
end
