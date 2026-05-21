defmodule SymphonyElixir.Orchestrator.PreDispatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.PreDispatch

  defp issue(opts) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-1"),
      identifier: Keyword.get(opts, :identifier, "SODEV-147"),
      title: Keyword.get(opts, :title, "Fix booking step 2"),
      description: Keyword.get(opts, :description, "x"),
      project_name: Keyword.get(opts, :project_name),
      state: "Scheduled"
    }
  end

  describe "check/1 — empty description rejection" do
    test "nil description is rejected" do
      assert {:reject, :empty_description, msg} = PreDispatch.check(issue(description: nil))
      assert msg =~ "description"
    end

    test "empty string description is rejected" do
      assert {:reject, :empty_description, _} = PreDispatch.check(issue(description: ""))
    end

    test "whitespace-only description is rejected" do
      assert {:reject, :empty_description, _} = PreDispatch.check(issue(description: "   \n\t  "))
    end
  end

  describe "check/1 — acceptable descriptions pass" do
    test "non-empty description returns :ok" do
      desc = """
      Add API endpoint POST /vendors/:id/promote that returns 200 when
      vendor.onboarding_status == 'complete'.
      """

      assert :ok = PreDispatch.check(issue(description: desc))
    end

    test "single-character description still passes (only empty is rejected)" do
      assert :ok = PreDispatch.check(issue(description: "x"))
    end
  end

  describe "check/1 — non-Issue input" do
    test "non-Issue struct returns :ok (degrades open, dispatch decides)" do
      assert :ok = PreDispatch.check(%{description: nil})
      assert :ok = PreDispatch.check(nil)
    end
  end

  describe "check/2 — unsupported project rejection" do
    test "exact match in unsupported list is rejected" do
      i = issue(project_name: "New Maestro 2.0")
      assert {:reject, :unsupported_project, msg} = PreDispatch.check(i, unsupported_projects: ["New Maestro 2.0"])
      assert msg =~ "New Maestro 2.0"
    end

    test "case- and whitespace-insensitive match still rejects" do
      i = issue(project_name: "  new maestro 2.0  ")
      assert {:reject, :unsupported_project, _} = PreDispatch.check(i, unsupported_projects: ["New Maestro 2.0"])
    end

    test "project not in unsupported list passes" do
      i = issue(project_name: "Schools Out core")
      assert :ok = PreDispatch.check(i, unsupported_projects: ["New Maestro 2.0"])
    end

    test "nil project_name passes (cannot deny what we cannot see)" do
      i = issue(project_name: nil)
      assert :ok = PreDispatch.check(i, unsupported_projects: ["New Maestro 2.0"])
    end

    test "whitespace-only project_name passes (normalizer strips, but defensive)" do
      i = issue(project_name: "   \n\t  ")
      assert :ok = PreDispatch.check(i, unsupported_projects: ["New Maestro 2.0"])
    end

    test "empty unsupported list is a no-op (default behavior)" do
      i = issue(project_name: "New Maestro 2.0")
      assert :ok = PreDispatch.check(i, unsupported_projects: [])
      assert :ok = PreDispatch.check(i)
    end

    test "empty description still beats project check (degenerate input first)" do
      i = issue(description: nil, project_name: "New Maestro 2.0")
      assert {:reject, :empty_description, _} = PreDispatch.check(i, unsupported_projects: ["New Maestro 2.0"])
    end
  end
end
