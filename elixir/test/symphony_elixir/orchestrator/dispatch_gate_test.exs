defmodule SymphonyElixir.Orchestrator.DispatchGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.DispatchGate

  describe "normalize_state/1" do
    test "downcases and trims" do
      assert DispatchGate.normalize_state("  In Progress  ") == "in progress"
      assert DispatchGate.normalize_state("Done") == "done"
      assert DispatchGate.normalize_state("") == ""
    end
  end

  describe "terminal_state?/2 and active_state?/2" do
    test "membership is normalized" do
      set = MapSet.new(["done", "merged"])
      assert DispatchGate.terminal_state?(" Done ", set) == true
      assert DispatchGate.terminal_state?("In Progress", set) == false
      refute DispatchGate.terminal_state?(:not_a_string, set)
      refute DispatchGate.terminal_state?(nil, set)

      active = MapSet.new(["in progress", "todo"])
      assert DispatchGate.active_state?("In Progress", active) == true
      refute DispatchGate.active_state?(123, active)
    end
  end

  describe "has_pr_attachment?/1" do
    test "true only when the field is exactly true" do
      assert DispatchGate.has_pr_attachment?(%Issue{id: "1", has_pr_attachment: true})
      refute DispatchGate.has_pr_attachment?(%Issue{id: "1", has_pr_attachment: false})
      refute DispatchGate.has_pr_attachment?(%{})
      refute DispatchGate.has_pr_attachment?(nil)
    end
  end

  describe "routable_to_worker?/1" do
    test "respects boolean field, defaults true" do
      assert DispatchGate.routable_to_worker?(%Issue{id: "1", assigned_to_worker: true})
      refute DispatchGate.routable_to_worker?(%Issue{id: "1", assigned_to_worker: false})
      assert DispatchGate.routable_to_worker?(%Issue{id: "1", assigned_to_worker: nil})
      assert DispatchGate.routable_to_worker?(%{})
    end
  end

  describe "todo_blocked_by_non_terminal?/2" do
    test "true when state=todo and a blocker is not in terminal set" do
      terminal = MapSet.new(["done"])

      blocked_issue = %Issue{
        id: "1",
        state: "Todo",
        blocked_by: [%{state: "In Progress"}]
      }

      assert DispatchGate.todo_blocked_by_non_terminal?(blocked_issue, terminal) == true
    end

    test "false when all blockers are terminal" do
      terminal = MapSet.new(["done"])

      issue = %Issue{
        id: "1",
        state: "todo",
        blocked_by: [%{state: "Done"}]
      }

      refute DispatchGate.todo_blocked_by_non_terminal?(issue, terminal)
    end

    test "false when state is not todo" do
      issue = %Issue{id: "1", state: "in progress", blocked_by: [%{state: "todo"}]}

      refute DispatchGate.todo_blocked_by_non_terminal?(issue, MapSet.new(["done"]))
    end

    test "treats malformed blockers as non-terminal" do
      terminal = MapSet.new(["done"])
      issue = %Issue{id: "1", state: "todo", blocked_by: [%{kind: :unknown}]}

      assert DispatchGate.todo_blocked_by_non_terminal?(issue, terminal) == true
    end

    test "catch-all returns false" do
      refute DispatchGate.todo_blocked_by_non_terminal?(%{}, MapSet.new())
    end
  end

  describe "candidate?/3" do
    setup do
      {:ok, active: MapSet.new(["in progress", "todo"]), terminal: MapSet.new(["done", "merged"])}
    end

    test "true for a routable Issue in an active, non-terminal state", %{
      active: a,
      terminal: t
    } do
      issue = %Issue{
        id: "1",
        identifier: "MT-1",
        title: "X",
        state: "In Progress",
        assigned_to_worker: true
      }

      assert DispatchGate.candidate?(issue, a, t)
    end

    test "false when not routable", %{active: a, terminal: t} do
      issue = %Issue{
        id: "1",
        identifier: "MT-1",
        title: "X",
        state: "In Progress",
        assigned_to_worker: false
      }

      refute DispatchGate.candidate?(issue, a, t)
    end

    test "false when terminal", %{active: a, terminal: t} do
      issue = %Issue{
        id: "1",
        identifier: "MT-1",
        title: "X",
        state: "Done"
      }

      refute DispatchGate.candidate?(issue, a, t)
    end

    test "catch-all returns false", %{active: a, terminal: t} do
      refute DispatchGate.candidate?(%{}, a, t)
    end
  end

  describe "retry_candidate?/2" do
    setup do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")
      :ok
    end

    test "false when issue is not a candidate" do
      refute DispatchGate.retry_candidate?(%{}, MapSet.new(["done"]))
    end

    test "true for routable, non-terminal, unblocked issue" do
      issue = %Issue{
        id: "1",
        identifier: "MT-1",
        title: "X",
        state: "In Progress",
        blocked_by: []
      }

      assert DispatchGate.retry_candidate?(issue, MapSet.new(["done"]))
    end

    test "false when todo and blocked" do
      issue = %Issue{
        id: "1",
        identifier: "MT-1",
        title: "X",
        state: "todo",
        blocked_by: [%{state: "in progress"}]
      }

      refute DispatchGate.retry_candidate?(issue, MapSet.new(["done"]))
    end
  end

  describe "revalidate/3" do
    setup do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")
      :ok
    end

    test ":ok when refreshed issue is still a retry candidate" do
      issue = %Issue{
        id: "abc",
        identifier: "MT-9",
        title: "X",
        state: "In Progress",
        blocked_by: []
      }

      fetcher = fn ["abc"] -> {:ok, [issue]} end

      assert {:ok, ^issue} = DispatchGate.revalidate(issue, fetcher, MapSet.new(["done"]))
    end

    test ":skip when refreshed issue is no longer a candidate" do
      stale = %Issue{
        id: "abc",
        identifier: "MT-9",
        title: "X",
        state: "Done",
        blocked_by: []
      }

      fetcher = fn ["abc"] -> {:ok, [stale]} end

      assert {:skip, ^stale} =
               DispatchGate.revalidate(%Issue{id: "abc"}, fetcher, MapSet.new(["done"]))
    end

    test ":skip :missing when fetcher returns empty" do
      assert {:skip, :missing} =
               DispatchGate.revalidate(%Issue{id: "abc"}, fn _ -> {:ok, []} end, MapSet.new())
    end

    test ":error passes through" do
      assert {:error, :boom} =
               DispatchGate.revalidate(
                 %Issue{id: "abc"},
                 fn _ -> {:error, :boom} end,
                 MapSet.new()
               )
    end

    test "catch-all returns {:ok, issue}" do
      assert {:ok, :not_an_issue} =
               DispatchGate.revalidate(:not_an_issue, fn _ -> {:ok, []} end, MapSet.new())
    end
  end

  describe "terminal_state_set/0 + active_state_set/0" do
    test "build sets from configured tracker state lists" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")

      terminal = DispatchGate.terminal_state_set()
      active = DispatchGate.active_state_set()

      assert is_struct(terminal, MapSet)
      assert is_struct(active, MapSet)
      assert MapSet.size(terminal) > 0
      assert MapSet.size(active) > 0
      assert MapSet.member?(terminal, "done")
    end
  end
end
