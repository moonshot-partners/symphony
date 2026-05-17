defmodule SymphonyElixir.Orchestrator.PreDispatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.PreDispatch

  defp issue(opts) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-1"),
      identifier: Keyword.get(opts, :identifier, "SODEV-147"),
      title: Keyword.get(opts, :title, "Fix booking step 2"),
      description: Keyword.get(opts, :description),
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
end
