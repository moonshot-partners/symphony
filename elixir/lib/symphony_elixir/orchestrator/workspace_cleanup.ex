defmodule SymphonyElixir.Orchestrator.WorkspaceCleanup do
  @moduledoc """
  Workspace-cleanup helpers extracted from `SymphonyElixir.Orchestrator`
  (CP18). `cleanup_for_identifier/2` is a thin wrapper around
  `Workspace.remove_issue_workspaces/2` that no-ops on non-binary
  identifiers. `run_terminal/0` is the startup pass that asks the
  configured `Tracker` for issues currently in a terminal state and
  cleans each one's workspace.

  Nothing here touches `Orchestrator` state — the helpers are surfaced
  as a sibling so the orchestrator can stay focused on the dispatch /
  reconcile loop. Side-effects (filesystem, network, logging) live
  inside the called collaborators (`Workspace`, `Tracker`, `Logger`).
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @doc """
  Remove the workspace directories belonging to `identifier` on
  `worker_host`. Returns `:ok` (and logs nothing) when `identifier`
  is not a binary.
  """
  @spec cleanup_for_identifier(any(), String.t() | nil) :: :ok | term()
  def cleanup_for_identifier(identifier, worker_host \\ nil)

  def cleanup_for_identifier(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  def cleanup_for_identifier(_identifier, _worker_host), do: :ok

  @doc """
  Walk every issue currently in a configured terminal state and run
  `cleanup_for_identifier/1` against it. Used once at orchestrator
  start-up to clear stale workspaces left behind by previous runs.
  Logs and continues when the tracker lookup fails.

  Accepts an injectable `:fetch_fn` (`(states -> {:ok, issues} | {:error, term()})`)
  and `:cleanup_fn` (`(identifier -> any())`) so tests can exercise
  the success, error, and per-issue paths without touching application
  env or the live `Tracker` / `Workspace` modules.
  """
  @spec run_terminal(keyword()) :: :ok
  def run_terminal(opts \\ []) do
    fetch_fn = Keyword.get(opts, :fetch_fn, &Tracker.fetch_issues_by_states/1)
    cleanup_fn = Keyword.get(opts, :cleanup_fn, &cleanup_for_identifier/1)
    terminal_states = Config.settings!().tracker.terminal_states

    case fetch_fn.(terminal_states) do
      {:ok, issues} ->
        Enum.each(issues, fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_fn.(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end

    :ok
  end
end
