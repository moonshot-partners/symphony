defmodule SymphonyElixir.RunLedger do
  @moduledoc """
  Append-only record of finished agent runs.

  While an agent runs, its trace and summary live in the orchestrator's in-memory
  snapshot (and the /live endpoint). When the run ends that state is dropped, so a
  ticket in `In Code Review` would otherwise show no trace or summary. This module
  persists one small line per finished run so the cockpit can surface them on
  tickets that are no longer running.

  `record_async/1` is the orchestrator's hot-path entry point: it spawns a Task so
  the Langfuse lookup never blocks orchestration, and writes a single jsonl line
  (kept small enough that the append is atomic even when several runs finish at
  once). Reads tolerate the occasional half-written or corrupt line.

  The ledger is forward-looking: only runs that finish after this is deployed get
  a record. Path is `SYMPHONY_RUN_LEDGER_PATH`, or
  `SYMPHONY_STATE_DIR/symphony_run_ledger.jsonl`, defaulting under the repo-level
  `state/` directory for local development.
  """

  require Logger

  alias SymphonyElixir.Langfuse

  @summary_limit 1500

  @doc "Resolved ledger file path."
  @spec path() :: String.t()
  def path do
    System.get_env("SYMPHONY_RUN_LEDGER_PATH") ||
      Path.join(state_dir(), "symphony_run_ledger.jsonl")
  end

  @doc """
  Fire-and-forget record of a finished run, called from the orchestrator. Resolves
  the trace off the orchestrator process and never raises into the caller.
  """
  # Task.start is typed as always {:ok, pid}, so dialyzer sees the :error fallback
  # as unreachable. It is a deliberate defensive guard, so silence the warning.
  @dialyzer {:nowarn_function, record_async: 1}
  @spec record_async(map()) :: {:ok, pid()} | :error
  def record_async(%{} = entry) do
    case Task.start(fn -> record(entry) end) do
      {:ok, pid} -> {:ok, pid}
      _ -> :error
    end
  end

  def record_async(_entry), do: :error

  @doc "Resolve the trace and append one ledger line. Returns :ok or :error."
  @spec record(map()) :: :ok | :error
  def record(%{identifier: identifier} = entry) when is_binary(identifier) do
    record = %{
      "identifier" => identifier,
      "traceUrl" => Langfuse.trace_url(Map.get(entry, :session_id)),
      "summary" => truncate(Map.get(entry, :summary)),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    path = path()
    File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(record) <> "\n", [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("run ledger write failed: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("run ledger record failed: #{inspect(error)}")
      :error
  end

  def record(_entry), do: :error

  @doc """
  Latest record per ticket identifier, read in one pass. Later lines win, so the
  most recent run for an identifier is returned. Unparseable lines are skipped.
  """
  @spec latest_by_identifier() :: %{optional(String.t()) => map()}
  def latest_by_identifier do
    path()
    |> read_lines()
    |> Enum.reduce(%{}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"identifier" => identifier} = record} when is_binary(identifier) ->
          Map.put(acc, identifier, record)

        _ ->
          acc
      end
    end)
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      _ -> []
    end
  end

  defp truncate(nil), do: nil
  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @summary_limit)
  defp truncate(value), do: value |> to_string() |> truncate()

  defp state_dir do
    System.get_env("SYMPHONY_STATE_DIR") ||
      Path.expand("../state", File.cwd!())
  end
end
