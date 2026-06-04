defmodule SymphonyElixir.RunLedgerTest do
  # async: false — uses SYMPHONY_RUN_LEDGER_PATH env and the global langfuse fetcher.
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunLedger

  setup do
    path = Path.join(System.tmp_dir!(), "run_ledger_test_#{System.unique_integer([:positive])}.jsonl")
    System.put_env("SYMPHONY_RUN_LEDGER_PATH", path)
    # Force trace resolution to a no-op so records never touch the network.
    Application.put_env(:symphony_elixir, :langfuse_trace_fetcher, fn _config, _turn -> :error end)

    on_exit(fn ->
      System.delete_env("SYMPHONY_RUN_LEDGER_PATH")
      Application.delete_env(:symphony_elixir, :langfuse_trace_fetcher)
      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "record then latest_by_identifier round-trips the summary", %{path: path} do
    assert :ok = RunLedger.record(%{identifier: "SODEV-1", session_id: "s", summary: "did the thing"})
    assert File.exists?(path)

    latest = RunLedger.latest_by_identifier()
    assert latest["SODEV-1"]["summary"] == "did the thing"
    assert latest["SODEV-1"]["traceUrl"] == nil
    assert is_binary(latest["SODEV-1"]["at"])
  end

  test "the latest record per identifier wins" do
    RunLedger.record(%{identifier: "SODEV-1", summary: "first"})
    RunLedger.record(%{identifier: "SODEV-1", summary: "second"})
    RunLedger.record(%{identifier: "SODEV-2", summary: "other"})

    latest = RunLedger.latest_by_identifier()
    assert latest["SODEV-1"]["summary"] == "second"
    assert latest["SODEV-2"]["summary"] == "other"
  end

  test "long summaries are truncated to keep the appended line small" do
    RunLedger.record(%{identifier: "SODEV-3", summary: String.duplicate("x", 5000)})

    assert String.length(RunLedger.latest_by_identifier()["SODEV-3"]["summary"]) == 1500
  end

  test "corrupt lines are skipped, valid records still read", %{path: path} do
    File.write(path, "not json at all\n", [:append])
    RunLedger.record(%{identifier: "SODEV-4", summary: "ok"})

    assert RunLedger.latest_by_identifier()["SODEV-4"]["summary"] == "ok"
  end

  test "a record without an identifier is a no-op" do
    assert :error = RunLedger.record(%{summary: "no id"})
    assert RunLedger.latest_by_identifier() == %{}
  end

  test "latest_by_identifier is empty when the ledger file does not exist" do
    System.put_env("SYMPHONY_RUN_LEDGER_PATH", Path.join(System.tmp_dir!(), "does_not_exist_#{System.unique_integer([:positive])}.jsonl"))
    assert RunLedger.latest_by_identifier() == %{}
  end

  test "record_async returns a live pid without blocking" do
    assert {:ok, pid} = RunLedger.record_async(%{identifier: "SODEV-5", summary: "y"})
    assert is_pid(pid)
  end
end
