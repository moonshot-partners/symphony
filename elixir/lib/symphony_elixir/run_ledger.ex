defmodule SymphonyElixir.RunLedger do
  @moduledoc """
  Append-only JSONL ledger of terminated agent runs.

  Each call to `record_run/2` appends one JSON object per line to the configured
  path. Designed for AI-native diagnostics: any agent (or human via Claude Code)
  reads the file directly with `File.read!/1` or `grep` — no UI required.

  Writes are gated by the `SYMPHONY_RUN_LEDGER=1` env var (see `enabled?/0`) so
  production rollout is staged. Callers in hot paths SHOULD wrap calls in
  `try/rescue` — a ledger failure must never propagate to orchestrator state.
  """

  @default_path "/opt/symphony/state/runs.jsonl"

  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("SYMPHONY_RUN_LEDGER") == "1"

  @spec record_run(map(), keyword()) :: :ok | {:error, term()}
  def record_run(run, opts \\ []) when is_map(run) do
    path = Keyword.get(opts, :path, @default_path)
    enriched = Map.put_new(run, :recorded_at, DateTime.utc_now() |> DateTime.to_iso8601())

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(enriched) do
      File.write(path, json <> "\n", [:append])
    end
  end

  @spec classify_outcome(map()) :: String.t()
  def classify_outcome(%{pr_merged_at: ts}) when is_binary(ts) and ts != "", do: "merged"
  def classify_outcome(%{pr_closed_at: ts}) when is_binary(ts) and ts != "", do: "closed_unmerged"
  def classify_outcome(%{pr_url: url}) when is_binary(url) and url != "", do: "pr_open"
  def classify_outcome(_), do: "no_pr"
end
