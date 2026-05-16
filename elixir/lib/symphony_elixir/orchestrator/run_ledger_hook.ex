defmodule SymphonyElixir.Orchestrator.RunLedgerHook do
  @moduledoc """
  Bridges `Orchestrator` termination paths into `SymphonyElixir.RunLedger`
  + `SymphonyElixir.RunLedger.Forensics`. Gated by `SYMPHONY_RUN_LEDGER=1`
  via `RunLedger.enabled?/0`. Any write failure is logged and swallowed —
  telemetry never propagates into orchestrator state.

  Two public entry points:
    * `build_run_map/2` — pure, returns the map shape persisted to disk.
    * `record/3`        — wraps build + writes with try/rescue + the flag
                          gate. Safe to call from any termination path.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunLedger.Forensics

  @spec record(map(), String.t(), keyword()) :: :ok
  def record(running_entry, issue_id, opts \\ [])
      when is_map(running_entry) and is_binary(issue_id) do
    if RunLedger.enabled?() do
      do_record(running_entry, issue_id, opts)
    else
      :ok
    end
  end

  @spec build_run_map(map(), String.t()) :: map()
  def build_run_map(running_entry, issue_id)
      when is_map(running_entry) and is_binary(issue_id) do
    issue = Map.get(running_entry, :issue)
    pr_url = extract_pr_url(issue)

    %{
      ticket: identifier_for(running_entry, issue) || issue_id,
      issue_id: issue_id,
      outcome: RunLedger.classify_outcome(%{pr_url: pr_url}),
      tokens: token_value(running_entry, :agent_total_tokens),
      tokens_in: token_value(running_entry, :agent_input_tokens),
      tokens_out: token_value(running_entry, :agent_output_tokens),
      turns: token_value(running_entry, :turn_count),
      retries: token_value(running_entry, :retry_attempt),
      pr_url: pr_url,
      session_id: Map.get(running_entry, :session_id),
      worker_host: Map.get(running_entry, :worker_host)
    }
  end

  defp do_record(running_entry, issue_id, opts) do
    run = build_run_map(running_entry, issue_id)

    ledger_opts =
      case Keyword.get(opts, :ledger_path) do
        nil -> []
        path -> [path: path]
      end

    forensics_opts =
      case Keyword.get(opts, :forensics_dir) do
        nil -> []
        dir -> [dir: dir]
      end

    try do
      _ = RunLedger.record_run(run, ledger_opts)
      _ = Forensics.append_attempt(run, forensics_opts)
      :ok
    rescue
      e ->
        Logger.warning("RunLedger write failed for issue_id=#{issue_id}: #{Exception.message(e)}")

        :ok
    end
  end

  defp identifier_for(%{identifier: id}, _) when is_binary(id), do: id
  defp identifier_for(_, %Issue{identifier: id}) when is_binary(id), do: id
  defp identifier_for(_, _), do: nil

  defp extract_pr_url(%Issue{repos: repos}) when is_list(repos) do
    Enum.find_value(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp extract_pr_url(_), do: nil

  defp token_value(entry, key) do
    case Map.get(entry, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
