defmodule SymphonyElixir.Orchestrator.WorkspaceCleanupTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.WorkspaceCleanup

  describe "cleanup_for_identifier/2" do
    test "delegates to Workspace.remove_issue_workspaces for binary identifiers" do
      assert :ok = WorkspaceCleanup.cleanup_for_identifier("SODEV-cleanup-1")
      assert :ok = WorkspaceCleanup.cleanup_for_identifier("SODEV-cleanup-2", "worker-a")
    end

    test "is a no-op when identifier is not a binary" do
      assert :ok = WorkspaceCleanup.cleanup_for_identifier(nil)
      assert :ok = WorkspaceCleanup.cleanup_for_identifier(:atom_identifier, "worker-a")
    end
  end

  describe "run_terminal/1" do
    test "invokes cleanup_fn for every Issue with a binary identifier" do
      issues = [
        %Issue{id: "1", identifier: "SODEV-1", title: "t", state: "Done"},
        %Issue{id: "2", identifier: "SODEV-2", title: "t", state: "Done"}
      ]

      parent = self()

      assert :ok =
               WorkspaceCleanup.run_terminal(
                 fetch_fn: fn _states -> {:ok, issues} end,
                 cleanup_fn: fn identifier -> send(parent, {:cleanup_called, identifier}) end
               )

      assert_received {:cleanup_called, "SODEV-1"}
      assert_received {:cleanup_called, "SODEV-2"}
    end

    test "skips entries without a binary identifier" do
      mixed = [
        %Issue{id: "1", identifier: "SODEV-1", title: "t", state: "Done"},
        %{not: "an issue"},
        %Issue{id: "2", identifier: nil, title: "t", state: "Done"}
      ]

      parent = self()

      assert :ok =
               WorkspaceCleanup.run_terminal(
                 fetch_fn: fn _states -> {:ok, mixed} end,
                 cleanup_fn: fn identifier -> send(parent, {:cleanup_called, identifier}) end
               )

      assert_received {:cleanup_called, "SODEV-1"}
      refute_received {:cleanup_called, nil}
    end

    test "logs a warning and returns :ok when the fetch fails" do
      log =
        capture_log(fn ->
          assert :ok =
                   WorkspaceCleanup.run_terminal(
                     fetch_fn: fn _states -> {:error, :boom} end,
                     cleanup_fn: fn _ -> flunk("cleanup must not be called when fetch fails") end
                   )
        end)

      assert log =~ "Skipping startup terminal workspace cleanup"
      assert log =~ ":boom"
    end

    test "uses the live Workspace cleanup as the default cleanup_fn" do
      issues = [%Issue{id: "1", identifier: "SODEV-DEFAULT", title: "t", state: "Done"}]

      assert :ok = WorkspaceCleanup.run_terminal(fetch_fn: fn _states -> {:ok, issues} end)
    end
  end
end
