defmodule SymphonyElixir.BoardStatesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Tracker
  alias SymphonyElixirWeb.ObservabilityApiController, as: Board

  describe "board_state_names/1" do
    test "unions every column's states, drops unset mappings, and dedups" do
      tracker = %Tracker{
        active_states: ["Scheduled"],
        in_progress_states: ["In Development"],
        review_state: "In Code Review",
        ready_state: "Approved QA",
        blocked_state: "On Hold / Blocked",
        # "Scheduled" is repeated to prove dedup keeps first-seen order.
        terminal_states: ["Released / Live", "Closed", "Scheduled"],
        done_extra_states: ["Recently released"]
      }

      assert Board.board_state_names(tracker) == [
               "Scheduled",
               "In Development",
               "In Code Review",
               "Approved QA",
               "On Hold / Blocked",
               "Released / Live",
               "Closed",
               "Recently released"
             ]
    end

    test "drops nil column mappings so the Linear filter never sees a nil state" do
      tracker = %Tracker{
        active_states: ["Scheduled"],
        in_progress_states: [],
        review_state: nil,
        ready_state: nil,
        blocked_state: nil,
        terminal_states: ["Closed"],
        done_extra_states: []
      }

      names = Board.board_state_names(tracker)

      assert names == ["Scheduled", "Closed"]
      refute Enum.any?(names, &is_nil/1)
    end
  end
end
