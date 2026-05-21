defmodule SymphonyElixir.Orchestrator.StateTest do
  @moduledoc """
  Defaults on the orchestrator's in-memory `%State{}` struct.

  Most fields are covered indirectly through reconcile / dispatch tests,
  but `pr_engagements` is a new field introduced by SYM-16 and the
  default-shape contract belongs here so a typo in the struct literal
  surfaces as a unit failure rather than as a runtime crash inside the
  PrReengagement sibling.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.State

  describe "%State{} defaults" do
    test "pr_engagements defaults to an empty map" do
      assert %State{}.pr_engagements == %{}
    end

    test "pr_engagements accepts the documented per-PR shape" do
      url = "https://github.com/org/repo/pull/1"

      state = %State{
        pr_engagements: %{url => %{count: 1, cap_hit_shas: MapSet.new(["abc"])}}
      }

      assert %{count: 1, cap_hit_shas: shas} = state.pr_engagements[url]
      assert MapSet.member?(shas, "abc")
    end
  end
end
