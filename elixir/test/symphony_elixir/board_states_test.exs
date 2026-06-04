defmodule SymphonyElixir.BoardStatesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Tracker
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.ObservabilityApiController, as: Board

  describe "ticket_payload/3" do
    setup do
      issue = %Issue{
        id: "issue-1",
        identifier: "SODEV-430",
        title: "Improve signup email typo detection",
        description: "do the thing",
        state: "In Code Review",
        url: "https://linear.app/x/SODEV-430"
      }

      ledger = %{
        "SODEV-430" => %{
          "summary" => "Shipped the typo detector and proved it non-blocking.",
          "traceUrl" => "https://langfuse.example/trace/abc"
        }
      }

      %{issue: issue, ledger: ledger}
    end

    test "keeps the last run summary visible while a fresh run is in flight", %{
      issue: issue,
      ledger: ledger
    } do
      running = MapSet.new(["issue-1"])

      payload = Board.ticket_payload(issue, running, ledger)

      assert payload.agent.status == "running"
      # The summary survives a re-dispatch instead of flickering to nothing.
      assert payload.summary == "Shipped the typo detector and proved it non-blocking."
      # The persisted trace is suppressed while running; the /live overlay owns it.
      assert payload.traceUrl == nil
    end

    test "surfaces the ledger summary and trace for an idle ticket", %{
      issue: issue,
      ledger: ledger
    } do
      payload = Board.ticket_payload(issue, MapSet.new(), ledger)

      assert payload.agent.status == "idle"
      assert payload.summary == "Shipped the typo detector and proved it non-blocking."
      assert payload.traceUrl == "https://langfuse.example/trace/abc"
    end

    test "summary and trace are nil when the ledger has no record for the ticket", %{issue: issue} do
      payload = Board.ticket_payload(issue, MapSet.new(), %{})

      assert payload.summary == nil
      assert payload.traceUrl == nil
    end
  end

  describe "board_state_names/1" do
    test "unions the live pipeline column states, drops unset mappings, and dedups" do
      tracker = %Tracker{
        active_states: ["Scheduled"],
        in_progress_states: ["In Development"],
        review_state: "In Code Review",
        ready_state: "Approved QA",
        # "Scheduled" repeated in done_extra to prove dedup keeps first-seen order.
        blocked_state: "Scheduled",
        terminal_states: ["Released / Live", "Closed"],
        done_extra_states: ["Recently released"]
      }

      assert Board.board_state_names(tracker) == [
               "Scheduled",
               "In Development",
               "In Code Review",
               "Approved QA",
               "Recently released"
             ]
    end

    test "excludes terminal states so Done shows only recently-shipped work" do
      tracker = %Tracker{
        active_states: ["Scheduled"],
        in_progress_states: ["In Development"],
        review_state: "In Code Review",
        ready_state: nil,
        blocked_state: "On Hold / Blocked",
        terminal_states: ["Closed", "Released / Live"],
        done_extra_states: ["Recently released"]
      }

      names = Board.board_state_names(tracker)

      assert names == ["Scheduled", "In Development", "In Code Review", "On Hold / Blocked", "Recently released"]
      refute "Closed" in names
      refute "Released / Live" in names
      refute Enum.any?(names, &is_nil/1)
    end
  end
end
