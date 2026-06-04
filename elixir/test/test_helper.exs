ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

# Default the run-ledger side-effect to a no-op so unrelated orchestrator tests
# never spawn a Task or touch the ledger file on agent-down. Tests that assert
# the ledger fires override :run_ledger_record_fn explicitly.
Application.put_env(:symphony_elixir, :run_ledger_record_fn, fn _entry -> :ok end)
