defmodule SymphonyElixir.Orchestrator.RunLedgerHookTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.RunLedgerHook

  setup do
    tmp = Path.join(System.tmp_dir!(), "run_ledger_hook_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    System.delete_env("SYMPHONY_RUN_LEDGER")

    on_exit(fn ->
      System.delete_env("SYMPHONY_RUN_LEDGER")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "build_run_map/2" do
    test "extracts identifier, pr_url, tokens, turns, retries from running entry" do
      issue = %Issue{
        id: "lin-1",
        identifier: "SODEV-99",
        repos: [%{name: "schools-out", pr: %{url: "https://github.com/x/y/pull/42", merged: false, review: nil}}]
      }

      running_entry = %{
        identifier: "SODEV-99",
        issue: issue,
        session_id: "sess-abc",
        worker_host: "vps-1",
        agent_input_tokens: 1500,
        agent_output_tokens: 700,
        agent_total_tokens: 2200,
        turn_count: 5,
        retry_attempt: 1
      }

      run = RunLedgerHook.build_run_map(running_entry, "lin-1")

      assert run.ticket == "SODEV-99"
      assert run.issue_id == "lin-1"
      assert run.pr_url == "https://github.com/x/y/pull/42"
      assert run.outcome == "pr_open"
      assert run.tokens == 2200
      assert run.tokens_in == 1500
      assert run.tokens_out == 700
      assert run.turns == 5
      assert run.retries == 1
      assert run.session_id == "sess-abc"
      assert run.worker_host == "vps-1"
    end

    test "no_pr outcome when issue has no GitHub PR attachment" do
      issue = %Issue{id: "lin-2", identifier: "SODEV-100", repos: []}
      running_entry = %{identifier: "SODEV-100", issue: issue, retry_attempt: 0, turn_count: 3}

      run = RunLedgerHook.build_run_map(running_entry, "lin-2")

      assert run.pr_url == nil
      assert run.outcome == "no_pr"
      assert run.tokens == 0
      assert run.turns == 3
      assert run.retries == 0
    end

    test "falls back to issue_id when no identifier present" do
      running_entry = %{retry_attempt: 0, turn_count: 0}
      run = RunLedgerHook.build_run_map(running_entry, "lin-3")
      assert run.ticket == "lin-3"
    end

    test "handles missing/nil fields without crashing" do
      run = RunLedgerHook.build_run_map(%{}, "lin-4")
      assert run.ticket == "lin-4"
      assert run.tokens == 0
      assert run.turns == 0
      assert run.retries == 0
      assert run.pr_url == nil
    end
  end

  describe "record/2 with flag disabled" do
    test "writes nothing when SYMPHONY_RUN_LEDGER unset", %{tmp: tmp} do
      ledger_path = Path.join(tmp, "runs.jsonl")
      forensics_dir = Path.join(tmp, "runs")

      :ok =
        RunLedgerHook.record(%{identifier: "T-1", issue: nil}, "id-1",
          ledger_path: ledger_path,
          forensics_dir: forensics_dir
        )

      refute File.exists?(ledger_path)
      refute File.exists?(forensics_dir)
    end
  end

  describe "record/2 with flag enabled" do
    setup do
      System.put_env("SYMPHONY_RUN_LEDGER", "1")
      :ok
    end

    test "appends one JSONL line and one forensics markdown attempt block", %{tmp: tmp} do
      ledger_path = Path.join(tmp, "runs.jsonl")
      forensics_dir = Path.join(tmp, "runs")

      issue = %Issue{
        id: "lin-9",
        identifier: "SODEV-9",
        repos: [%{name: "x", pr: %{url: "https://github.com/o/r/pull/1", merged: false, review: nil}}]
      }

      running_entry = %{
        identifier: "SODEV-9",
        issue: issue,
        agent_input_tokens: 100,
        agent_output_tokens: 50,
        agent_total_tokens: 150,
        turn_count: 2,
        retry_attempt: 0,
        session_id: "s-1"
      }

      :ok =
        RunLedgerHook.record(running_entry, "lin-9",
          ledger_path: ledger_path,
          forensics_dir: forensics_dir
        )

      assert File.exists?(ledger_path)
      [line] = ledger_path |> File.read!() |> String.split("\n", trim: true)
      json = Jason.decode!(line)
      assert json["ticket"] == "SODEV-9"
      assert json["outcome"] == "pr_open"
      assert json["pr_url"] == "https://github.com/o/r/pull/1"
      assert json["tokens"] == 150

      md_path = Path.join(forensics_dir, "SODEV-9.md")
      assert File.exists?(md_path)
      body = File.read!(md_path)
      assert body =~ "## Attempt 1"
      assert body =~ "Outcome: pr_open"
      assert body =~ "Tokens: 150"
    end

    test "never raises even if write target is invalid", %{tmp: tmp} do
      bogus = Path.join(tmp, "this/path/cannot/exist/runs.jsonl")
      bogus_dir = "/proc/forbidden/runs"

      assert :ok =
               RunLedgerHook.record(%{identifier: "T-X", issue: nil}, "id-x",
                 ledger_path: bogus,
                 forensics_dir: bogus_dir
               )
    end
  end
end
