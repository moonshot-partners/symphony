defmodule SymphonyElixir.RunLedgerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunLedger

  setup do
    tmp = Path.join(System.tmp_dir!(), "run_ledger_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "record_run/2" do
    test "appends one JSON line per call", %{tmp: tmp} do
      path = Path.join(tmp, "runs.jsonl")
      assert :ok = RunLedger.record_run(%{ticket: "T-1", outcome: "merged"}, path: path)
      assert :ok = RunLedger.record_run(%{ticket: "T-2", outcome: "closed_unmerged"}, path: path)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
      assert Jason.decode!(Enum.at(lines, 0))["ticket"] == "T-1"
      assert Jason.decode!(Enum.at(lines, 1))["outcome"] == "closed_unmerged"
    end

    test "adds recorded_at ISO8601 timestamp", %{tmp: tmp} do
      path = Path.join(tmp, "runs.jsonl")
      :ok = RunLedger.record_run(%{ticket: "T-1", outcome: "merged"}, path: path)
      [line] = path |> File.read!() |> String.split("\n", trim: true)
      ts = Jason.decode!(line)["recorded_at"]
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(ts)
    end

    test "preserves caller-supplied recorded_at", %{tmp: tmp} do
      path = Path.join(tmp, "runs.jsonl")
      caller_ts = "2026-01-01T00:00:00Z"
      :ok = RunLedger.record_run(%{ticket: "T-1", recorded_at: caller_ts}, path: path)
      [line] = path |> File.read!() |> String.split("\n", trim: true)
      assert Jason.decode!(line)["recorded_at"] == caller_ts
    end

    test "creates parent dir if missing", %{tmp: tmp} do
      nested = Path.join([tmp, "deep", "nested", "runs.jsonl"])
      :ok = RunLedger.record_run(%{ticket: "T-1", outcome: "merged"}, path: nested)
      assert File.exists?(nested)
    end
  end

  describe "classify_outcome/1" do
    test "merged when pr_merged_at present" do
      assert RunLedger.classify_outcome(%{pr_merged_at: "2026-05-16T10:00:00Z"}) == "merged"
    end

    test "closed_unmerged when pr_closed_at present without merged" do
      assert RunLedger.classify_outcome(%{pr_closed_at: "2026-05-16T10:00:00Z"}) == "closed_unmerged"
    end

    test "pr_open when pr_url present without close/merge" do
      assert RunLedger.classify_outcome(%{pr_url: "https://github.com/x/y/pull/1"}) == "pr_open"
    end

    test "no_pr when nothing PR-related" do
      assert RunLedger.classify_outcome(%{}) == "no_pr"
    end

    test "no_pr when pr_url is empty string" do
      assert RunLedger.classify_outcome(%{pr_url: ""}) == "no_pr"
    end
  end

  describe "enabled?/0" do
    test "returns true when SYMPHONY_RUN_LEDGER=1" do
      System.put_env("SYMPHONY_RUN_LEDGER", "1")
      assert RunLedger.enabled?() == true
      System.delete_env("SYMPHONY_RUN_LEDGER")
    end

    test "returns false when unset" do
      System.delete_env("SYMPHONY_RUN_LEDGER")
      assert RunLedger.enabled?() == false
    end

    test "returns false for other values" do
      System.put_env("SYMPHONY_RUN_LEDGER", "true")
      assert RunLedger.enabled?() == false
      System.delete_env("SYMPHONY_RUN_LEDGER")
    end
  end
end
