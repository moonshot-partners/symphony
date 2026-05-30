defmodule SymphonyElixir.Orchestrator.PrReengagementTest do
  @moduledoc """
  Unit coverage for the SYM-16 auto re-engagement loop.

  `PrReengagement.run/2` walks `state.completed`, asks the injected
  detector whether each issue's PR carries a fresh critical review, and
  either:

    * DISPATCH (count < 2) — increments `state.pr_engagements[pr_url].count`,
      removes the id from `state.completed`, transitions the issue back to
      the configured `on_pickup_state` so DispatchGate picks it up on the
      next tick, and posts a threaded workpad comment.

    * CAP-IGNORE (count >= 2, new head_sha) — records the head_sha in
      `cap_hit_shas` and leaves Linear untouched.

    * CAP-IGNORE DEDUP (count >= 2, head_sha already in cap_hit_shas) —
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
      assert body =~ "PR review gate"
      assert body =~ "automatic re-engagement 1 of 2"
      assert body =~ "3"
    end

    test "DISPATCH (count == 1): allows second re-engagement before the cap" do
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

      assert %{count: 2, cap_hit_shas: shas} = new_state.pr_engagements[pr_url]
      assert MapSet.size(shas) == 0

      refute MapSet.member?(new_state.completed, "i-77")

      assert_receive {:transitioned, "Scheduled"}, 500

      assert_receive {:commented, "i-77", body, "wp-i-77"}, 500
      assert body =~ "automatic re-engagement 2 of 2"
      assert body =~ "ignored by Symphony"
    end

    test "CAP reached (count >= 2): evicts issue without transition or comment" do
      parent = self()
      pr_url = "https://github.com/org/repo/pull/77"

      issue = issue("i-77", pr_url)

      state =
        build_state(
          %{"i-77" => issue},
          %{pr_url => %{count: 2, cap_hit_shas: MapSet.new()}}
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

      # Cap reached: the issue is evicted from completed and no Linear
      # side-effect fires. The cap count survives in pr_engagements.
      refute MapSet.member?(new_state.completed, "i-77")
      assert %{count: 2} = new_state.pr_engagements[pr_url]

      refute_receive {:transitioned, _}, 50
      refute_receive {:commented, _, _, _}, 50
    end

    test "CAP reached on the critical PR of a multi-repo issue evicts the issue" do
      parent = self()
      rails_pr = "https://github.com/org/rails/pull/936"
      fe_pr = "https://github.com/org/fe-next-app/pull/617"

      issue = %Issue{
        id: "i-multi",
        identifier: "ISS-MULTI",
        state: "Done",
        repos: [
          %{name: "schools-out", pr: %{url: rails_pr}},
          %{name: "fe-next-app", pr: %{url: fe_pr}}
        ]
      }

      state =
        build_state(
          %{"i-multi" => issue},
          %{fe_pr => %{count: 2, cap_hit_shas: MapSet.new()}}
        )

      verdict =
        {:critical,
         %{
           count: 5,
           items: ["critical frontend review"],
           head_sha: "fe-sha-2",
           pr_url: fe_pr
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
            {:ok, "c-multi"}
          end
        })

      new_state = PrReengagement.run(state, opts)

      refute Map.has_key?(new_state.pr_engagements, rails_pr)
      assert %{count: 2} = new_state.pr_engagements[fe_pr]
      refute MapSet.member?(new_state.completed, "i-multi")

      refute_receive {:transitioned, _}, 50
      refute_receive {:commented, _, _, _}, 50
    end

    test "evicts a completed issue that has no PR url" do
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

      new_state = PrReengagement.run(state, opts)

      # No PR means nothing to re-engage on, so the issue is dropped from
      # state.completed and will not be re-scanned every poll cycle.
      refute MapSet.member?(new_state.completed, "i-no-pr")
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

    test "evicts a completed issue whose repos carry no PR yet (defensive flat_map fallback)" do
      parent = self()

      issue_repo_no_pr = %Issue{
        id: "i-pre-pr",
        identifier: "ISS-PREPR",
        state: "Done",
        repos: [%{name: "fe-next-app", pr: nil}]
      }

      state = build_state(%{"i-pre-pr" => issue_repo_no_pr})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [issue_repo_no_pr]} end,
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

      new_state = PrReengagement.run(state, opts)

      refute MapSet.member?(new_state.completed, "i-pre-pr")
      refute_receive :detector_called, 50
      refute_receive :transitioned, 50
      refute_receive :commented, 50
    end

    test "DISPATCH body renders '(no items listed)' when items list is empty" do
      parent = self()
      pr_url = "https://github.com/org/repo/pull/12"

      state = build_state(%{"i-empty" => issue("i-empty", pr_url)})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [issue("i-empty", pr_url)]} end,
          detector_fn: fn _issue ->
            {:critical, %{count: 0, items: [], head_sha: "sha-empty"}}
          end,
          state_transition_fn: fn _issue, _target -> :ok end,
          comment_fn: fn _id, body, _parent ->
            send(parent, {:commented, body})
            {:ok, "c"}
          end
        })

      _ = PrReengagement.run(state, opts)

      assert_receive {:commented, body}, 50
      assert body =~ "(no items listed)"
    end
  end

  describe "DecisionLog emissions" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "pr_reengagement_log_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      path = Path.join(tmp, "decisions.jsonl")

      prior_app = Application.get_env(:symphony_elixir, :decision_log_path)
      prior_env = System.get_env("SYMPHONY_DECISION_LOG")
      Application.put_env(:symphony_elixir, :decision_log_path, path)
      System.put_env("SYMPHONY_DECISION_LOG", "1")

      on_exit(fn ->
        File.rm_rf!(tmp)

        case prior_app do
          nil -> Application.delete_env(:symphony_elixir, :decision_log_path)
          val -> Application.put_env(:symphony_elixir, :decision_log_path, val)
        end

        case prior_env do
          nil -> System.delete_env("SYMPHONY_DECISION_LOG")
          val -> System.put_env("SYMPHONY_DECISION_LOG", val)
        end
      end)

      {:ok, ledger_path: path}
    end

    defp ledger_events(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(& &1["event"])
    end

    test "emits run + dispatch on the happy path", %{ledger_path: path} do
      parent = self()
      pr_url = "https://github.com/o/r/pull/1"
      iss = issue("i-disp", pr_url)
      state = build_state(%{"i-disp" => iss})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [iss]} end,
          detector_fn: fn _issue ->
            {:critical, %{count: 1, items: ["x"], head_sha: "sha-1"}}
          end,
          state_transition_fn: fn _issue, _target -> :ok end,
          comment_fn: fn _id, _body, _parent ->
            send(parent, :commented)
            {:ok, "c"}
          end
        })

      _ = PrReengagement.run(state, opts)
      assert_receive :commented, 50

      events = ledger_events(path)
      assert "pr_reengagement.run" in events
      assert "pr_reengagement.dispatch" in events
    end

    test "emits skip_no_pr when issue has no PR url", %{ledger_path: path} do
      iss = %Issue{id: "i-nopr", identifier: "ISS-i-nopr", state: "Done", repos: []}
      state = build_state(%{"i-nopr" => iss})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [iss]} end,
          detector_fn: fn _issue -> raise "should not be called" end,
          state_transition_fn: fn _issue, _target -> :ok end,
          comment_fn: fn _id, _body, _parent -> {:ok, "c"} end
        })

      _ = PrReengagement.run(state, opts)
      assert "pr_reengagement.skip_no_pr" in ledger_events(path)
    end

    test "emits skip_no_critical when detector returns :none", %{ledger_path: path} do
      pr_url = "https://github.com/o/r/pull/2"
      iss = issue("i-none", pr_url)
      state = build_state(%{"i-none" => iss})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [iss]} end,
          detector_fn: fn _issue -> :none end,
          state_transition_fn: fn _issue, _target -> :ok end,
          comment_fn: fn _id, _body, _parent -> {:ok, "c"} end
        })

      _ = PrReengagement.run(state, opts)
      assert "pr_reengagement.skip_no_critical" in ledger_events(path)
    end

    test "emits cap_reached_evict and drops the issue when its PR is at the cap", %{ledger_path: path} do
      pr_url = "https://github.com/o/r/pull/3"
      iss = issue("i-cap", pr_url)

      state =
        build_state(%{"i-cap" => iss}, %{
          pr_url => %{count: 2, cap_hit_shas: MapSet.new()}
        })

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:ok, [iss]} end,
          detector_fn: fn _issue ->
            {:critical, %{count: 2, items: ["y"], head_sha: "sha-cap"}}
          end,
          state_transition_fn: fn _issue, _target -> :ok end,
          comment_fn: fn _id, _body, _parent -> {:ok, "c"} end
        })

      new_state = PrReengagement.run(state, opts)

      assert "pr_reengagement.cap_reached_evict" in ledger_events(path)
      refute MapSet.member?(new_state.completed, "i-cap")
    end

    test "emits fetch_error when issue_fetch_fn errors", %{ledger_path: path} do
      iss = issue("i-err", "https://github.com/o/r/pull/4")
      state = build_state(%{"i-err" => iss})

      opts =
        opts(%{
          issue_fetch_fn: fn _ids -> {:error, :boom} end,
          detector_fn: fn _issue -> raise "should not be called" end,
          state_transition_fn: fn _issue, _target -> :ok end,
          comment_fn: fn _id, _body, _parent -> {:ok, "c"} end
        })

      _ = PrReengagement.run(state, opts)
      assert "pr_reengagement.fetch_error" in ledger_events(path)
    end
  end
end
