defmodule SymphonyElixir.Orchestrator.TurnSoftCapTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.TurnSoftCap

  describe "evaluate/2 — pure soft-cap decision" do
    test "returns :noop when disabled in settings" do
      entry = %{turn_count: 19, identifier: "X-1"}

      settings = %{
        enabled: false,
        ratio: 0.80,
        max_turns: 20
      }

      assert :noop = TurnSoftCap.evaluate(entry, settings)
    end

    test "returns :noop when turn_count below ratio threshold" do
      entry = %{turn_count: 15, identifier: "X-1"}

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert :noop = TurnSoftCap.evaluate(entry, settings)
    end

    test "returns {:warn, message, updated_entry} when turn_count crosses ratio and not yet warned" do
      entry = %{turn_count: 16, identifier: "X-1"}

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert {:warn, message, updated} = TurnSoftCap.evaluate(entry, settings)
      assert is_binary(message)
      assert String.contains?(message, "16/20")
      assert String.contains?(message, "Approaching turn cap")
      assert updated.soft_cap_warned == true
    end

    test "returns :noop when ratio met but already warned" do
      entry = %{turn_count: 17, identifier: "X-1", soft_cap_warned: true}

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert :noop = TurnSoftCap.evaluate(entry, settings)
    end

    test "returns {:exhaust, message, updated_entry} at turn_count == max_turns" do
      entry = %{turn_count: 20, identifier: "X-1", soft_cap_warned: true}

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert {:exhaust, message, updated} = TurnSoftCap.evaluate(entry, settings)
      assert is_binary(message)
      assert String.contains?(message, "20/20")
      assert String.contains?(message, "Time-exhausted")
      assert updated.soft_cap_exhausted == true
    end

    test "returns :noop after exhaust already fired (idempotent)" do
      entry = %{
        turn_count: 20,
        identifier: "X-1",
        soft_cap_warned: true,
        soft_cap_exhausted: true
      }

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert :noop = TurnSoftCap.evaluate(entry, settings)
    end

    test "tolerates fractional ratios — 0.6 of 25 triggers warn at turn 15" do
      entry = %{turn_count: 15, identifier: "X-1"}

      settings = %{enabled: true, ratio: 0.60, max_turns: 25}

      assert {:warn, _msg, updated} = TurnSoftCap.evaluate(entry, settings)
      assert updated.soft_cap_warned == true
    end

    test "tolerates missing turn_count gracefully (treats as 0)" do
      entry = %{identifier: "X-1"}

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert :noop = TurnSoftCap.evaluate(entry, settings)
    end

    test "skips warn and goes straight to exhaust when turn_count == max_turns and not yet warned" do
      entry = %{turn_count: 20, identifier: "X-1"}

      settings = %{enabled: true, ratio: 0.80, max_turns: 20}

      assert {:exhaust, _msg, updated} = TurnSoftCap.evaluate(entry, settings)
      assert updated.soft_cap_exhausted == true
      refute Map.get(updated, :soft_cap_warned, false)
    end
  end

  describe "maybe_emit/3 — side effects via memory tracker" do
    setup do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "Rejected",
        tracker_on_exhaust_state: "On Hold / Time Exhausted",
        max_turns: 20,
        soft_cap_enabled: true,
        soft_cap_ratio: 0.80
      )

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      :ok
    end

    defp entry(overrides) do
      base = %{
        identifier: "SODEV-100",
        issue: %Issue{
          id: "issue-abc",
          identifier: "SODEV-100",
          title: "Long ticket",
          state: "In Progress",
          url: "https://linear.app/issues/SODEV-100"
        },
        turn_count: 0,
        workpad_comment_id: nil
      }

      Map.merge(base, overrides)
    end

    defp pr_attached_issue(has_pr) do
      %Issue{
        id: "issue-abc",
        identifier: "SODEV-100",
        title: "Long ticket",
        state: "In Progress",
        url: "https://linear.app/issues/SODEV-100",
        has_pr_attachment: has_pr,
        repos: [
          %{
            name: "schools-out",
            pr: %{url: "https://github.com/schoolsoutapp/schools-out/pull/999"}
          }
        ]
      }
    end

    test "returns entry unchanged for non turn_completed events" do
      e = entry(%{turn_count: 17})

      result = TurnSoftCap.maybe_emit(e, %{event: :pr_attached}, "issue-abc")
      assert result == e
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "fires warn at 80% threshold and posts to workpad with parent_id when present" do
      e = entry(%{turn_count: 16, workpad_comment_id: "wp-1"})

      result = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")
      assert result.soft_cap_warned == true

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "Approaching turn cap"
      assert body =~ "16/20"
    end

    test "fires exhaust at max_turns with ready PR — transitions to on_exhaust_state (env-blocked)" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_ready_fn) end)

      e =
        entry(%{
          turn_count: 20,
          soft_cap_warned: true,
          issue: pr_attached_issue(true)
        })

      result = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")
      assert result.soft_cap_exhausted == true

      assert_receive {:memory_tracker_comment, "issue-abc", body}, 2000
      assert body =~ "Time-exhausted"

      assert_receive {:memory_tracker_state_update, "issue-abc", "On Hold / Time Exhausted"}, 2000
    end

    test "exhaust with ready PR falls back to on_reject_state when on_exhaust_state is unset" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_on_reject_state: "Rejected",
        tracker_on_exhaust_state: nil,
        max_turns: 20,
        soft_cap_enabled: true,
        soft_cap_ratio: 0.80
      )

      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> true end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_ready_fn) end)

      e =
        entry(%{
          turn_count: 20,
          soft_cap_warned: true,
          issue: pr_attached_issue(true)
        })

      _ = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_state_update, "issue-abc", "Rejected"}, 2000
    end

    test "SYM-13 AC2: exhaust without a PR routes to on_reject_state (anti-abuse, no env-blocked)" do
      e = entry(%{turn_count: 20, soft_cap_warned: true})

      _ = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_state_update, "issue-abc", "Rejected"}, 2000
      refute_receive {:memory_tracker_state_update, "issue-abc", "On Hold / Time Exhausted"}, 200
    end

    test "SYM-13 AC2: exhaust with PR but red CI routes to on_reject_state (anti-abuse)" do
      Application.put_env(:symphony_elixir, :pr_ready_fn, fn _url -> false end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :pr_ready_fn) end)

      e =
        entry(%{
          turn_count: 20,
          soft_cap_warned: true,
          issue: pr_attached_issue(true)
        })

      _ = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")

      assert_receive {:memory_tracker_state_update, "issue-abc", "Rejected"}, 2000
      refute_receive {:memory_tracker_state_update, "issue-abc", "On Hold / Time Exhausted"}, 200
    end

    test "no comment fires when disabled via config" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_turns: 20,
        soft_cap_enabled: false,
        soft_cap_ratio: 0.80
      )

      e = entry(%{turn_count: 20})
      result = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")
      assert result == e
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "logs warning when Tracker.create_comment returns error" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result) end)

      e = entry(%{turn_count: 16})

      log =
        capture_log([level: :warning], fn ->
          _ = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")
          Process.sleep(100)
        end)

      assert log =~ "TurnSoftCap soft-cap warn post failed"
      assert log =~ "boom"
    end

    test "skips state transition when running entry has no :issue" do
      e =
        entry(%{turn_count: 20, soft_cap_warned: true})
        |> Map.delete(:issue)

      _ = TurnSoftCap.maybe_emit(e, %{event: :turn_completed}, "issue-abc")
      assert_receive {:memory_tracker_comment, "issue-abc", _}, 2000
      refute_receive {:memory_tracker_state_update, _, _}, 200
    end
  end
end
