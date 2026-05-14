defmodule SymphonyElixir.OrchestratorPrLabelTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.PrUrl

  describe "PrUrl.parse/1" do
    test "parses standard GitHub PR URL" do
      url = "https://github.com/schoolsoutapp/schools-out/pull/789"
      assert PrUrl.parse(url) == {:ok, "schoolsoutapp", "schools-out", 789}
    end

    test "parses URL with trailing slash" do
      url = "https://github.com/schoolsoutapp/fe-next-app/pull/460/"
      assert PrUrl.parse(url) == {:ok, "schoolsoutapp", "fe-next-app", 460}
    end

    test "returns error for non-PR URL" do
      assert PrUrl.parse("https://github.com/owner/repo") == :error
    end

    test "returns error for nil" do
      assert PrUrl.parse(nil) == :error
    end

    test "returns error for non-string" do
      assert PrUrl.parse(42) == :error
    end
  end
end
