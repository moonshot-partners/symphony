defmodule SymphonyElixir.Cockpit.RunSummaryStore do
  @moduledoc """
  On-box store for a run's completion summary, shown in the cockpit ticket
  detail instead of posted as a tracker comment. One markdown file per issue
  (keyed by the orchestrator's internal issue id), overwritten each completion.

  Root is `SYMPHONY_COCKPIT_SUMMARY_DIR` (default
  `/opt/symphony/state/run-summaries`). Deliberately separate from the QA
  evidence store: both writers fire at completion time as concurrent tasks, so
  keeping them in different directories means they never race on the same path.
  """

  require Logger

  @default_dir "/opt/symphony/state/run-summaries"

  @spec dir() :: String.t()
  def dir, do: System.get_env("SYMPHONY_COCKPIT_SUMMARY_DIR") || @default_dir

  @doc """
  Write (overwrite) the per-issue completion summary markdown. Non-raising and
  best-effort: a local-disk failure is logged, never propagated, so a summary
  write can run synchronously on the orchestrator path without risking a crash.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(issue_id, markdown) when is_binary(issue_id) and is_binary(markdown) do
    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(file(issue_id), markdown) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("RunSummaryStore put failed issue=#{issue_id} reason=#{inspect(reason)}")
        :ok
    end
  end

  @doc "The per-issue completion summary markdown, or `nil` when none is stored."
  @spec read(String.t()) :: String.t() | nil
  def read(issue_id) when is_binary(issue_id) do
    case File.read(file(issue_id)) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  @doc """
  Remove the stored completion summary for an issue.

  Destructive reruns call this before the new attempt is queued so the cockpit
  no longer displays stale completion text from the previous run.
  """
  @spec delete(String.t()) :: :ok
  def delete(issue_id) when is_binary(issue_id) do
    case File.rm(file(issue_id)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("RunSummaryStore delete failed issue=#{issue_id} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp file(issue_id), do: Path.join(dir(), sanitize(issue_id) <> ".md")

  defp sanitize(issue_id), do: String.replace(issue_id, ~r/[^A-Za-z0-9._-]/, "_")
end
