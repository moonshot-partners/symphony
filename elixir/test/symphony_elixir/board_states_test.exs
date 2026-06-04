defmodule SymphonyElixir.BoardStatesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Tracker
  alias SymphonyElixirWeb.ObservabilityApiController, as: Board

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
