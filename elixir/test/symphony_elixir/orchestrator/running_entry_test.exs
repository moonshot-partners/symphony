defmodule SymphonyElixir.Orchestrator.RunningEntryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{RunningEntry, State}

  defp issue(id, identifier \\ "SODEV-1"), do: %Issue{id: id, identifier: identifier, title: "t"}

  describe "find_issue_by_id/2" do
    test "returns the matching Issue struct" do
      assert RunningEntry.find_issue_by_id([issue("a", "A"), issue("b", "B")], "b") ==
               issue("b", "B")
    end

    test "returns nil when no Issue matches" do
      assert RunningEntry.find_issue_by_id([issue("a"), issue("b")], "z") == nil
    end

    test "ignores list elements that are not Issue structs" do
      assert RunningEntry.find_issue_by_id([%{id: "a"}, issue("b", "B")], "b") == issue("b", "B")
      assert RunningEntry.find_issue_by_id([%{id: "a"}, %{id: "b"}], "b") == nil
    end
  end

  describe "find_id_for_ref/2" do
    test "returns the issue_id whose running entry holds the matching monitor ref" do
      ref = make_ref()
      running = %{"iss-1" => %{ref: make_ref()}, "iss-2" => %{ref: ref}}
      assert RunningEntry.find_id_for_ref(running, ref) == "iss-2"
    end

    test "returns nil when no entry carries the ref" do
      assert RunningEntry.find_id_for_ref(%{"iss-1" => %{ref: make_ref()}}, make_ref()) == nil
    end

    test "returns nil for an empty running map" do
      assert RunningEntry.find_id_for_ref(%{}, make_ref()) == nil
    end
  end

  describe "session_id/1" do
    test "returns the session_id binary when present" do
      assert RunningEntry.session_id(%{session_id: "sess-42"}) == "sess-42"
    end

    test "falls back to \"n/a\" when missing or non-binary" do
      assert RunningEntry.session_id(%{}) == "n/a"
      assert RunningEntry.session_id(%{session_id: nil}) == "n/a"
      assert RunningEntry.session_id(%{session_id: 123}) == "n/a"
      assert RunningEntry.session_id(:not_a_map) == "n/a"
    end
  end

  describe "put_runtime_value/3" do
    test "puts the value into the entry when value is non-nil" do
      assert RunningEntry.put_runtime_value(%{a: 1}, :b, "v") == %{a: 1, b: "v"}
    end

    test "returns the entry unchanged when value is nil" do
      entry = %{a: 1}
      assert RunningEntry.put_runtime_value(entry, :b, nil) == entry
    end
  end

  describe "put_workpad_comment_id/2" do
    test "stores the comment_id binary into the entry" do
      assert RunningEntry.put_workpad_comment_id(%{}, "cmt-1") == %{workpad_comment_id: "cmt-1"}
    end

    test "returns the entry unchanged when comment_id is nil" do
      assert RunningEntry.put_workpad_comment_id(%{a: 1}, nil) == %{a: 1}
    end
  end

  describe "format_context/1" do
    test "renders the orchestrator's standard log fragment" do
      assert RunningEntry.format_context(issue("iss-1", "SODEV-7")) ==
               "issue_id=iss-1 issue_identifier=SODEV-7"
    end
  end

  describe "pop/2" do
    test "removes the entry from state.running and returns it along with the new state" do
      state = %State{running: %{"iss-1" => %{pid: self()}, "iss-2" => %{pid: self()}}}

      {entry, new_state} = RunningEntry.pop(state, "iss-1")
      assert entry == %{pid: self()}
      assert Map.keys(new_state.running) == ["iss-2"]
    end

    test "returns {nil, unchanged state} when the issue is not present" do
      state = %State{running: %{"iss-1" => %{}}}
      {entry, new_state} = RunningEntry.pop(state, "missing")
      assert entry == nil
      assert new_state == state
    end
  end
end
