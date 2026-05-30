defmodule SymphonyElixir.Orchestrator.TurnArtifacts do
  @moduledoc """
  Discovers `state/*/understanding.md` at any depth under the agent workspace.

  The agent names the state directory after the ticket id, not Symphony's
  session_id, and writes it either at the workspace root or under a repo
  subdir, so the path is discovered by a recursive glob and the
  most-recently-modified match wins when several exist.

  The artifact is kept out of the public Linear thread during normal runs.
  The final debug bundle includes it for deeper troubleshooting, while gates
  such as plan grounding and conflict disclosure can still read it here.

  Pure side-effect: logs discovery and returns `:ok`. Does not mutate the
  running_entry.
  """

  require Logger

  @spec maybe_post(map(), map(), String.t()) :: :ok
  def maybe_post(running_entry, %{event: :turn_completed}, issue_id) do
    with 1 <- Map.get(running_entry, :turn_count),
         workspace_path when is_binary(workspace_path) <- Map.get(running_entry, :workspace_path) do
      parent_id = Map.get(running_entry, :workpad_comment_id)
      identifier = Map.get(running_entry, :identifier, issue_id)
      post_understanding_md(workspace_path, issue_id, identifier, parent_id)
    end

    :ok
  end

  def maybe_post(_running_entry, _update, _issue_id), do: :ok

  defp post_understanding_md(workspace_path, _issue_id, identifier, _parent_id) do
    case discover_understanding_md(workspace_path) do
      nil ->
        Logger.debug("TurnArtifacts: understanding.md not found under #{workspace_path}/**/state/*")

      path ->
        log_understanding_md(path, identifier)
    end
  end

  @doc """
  Finds the most-recently-modified `state/*/understanding.md` at any depth
  under `workspace_path`, or `nil` when none exists. Public so the
  plan-grounding gate reads the same artifact this module posts.
  """
  @spec discover_understanding_md(String.t()) :: String.t() | nil
  def discover_understanding_md(workspace_path) do
    Path.join([workspace_path, "**", "state", "*", "understanding.md"])
    |> Path.wildcard()
    |> Enum.max_by(&file_mtime/1, fn -> nil end)
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end

  defp log_understanding_md(path, identifier) do
    case File.read(path) do
      {:ok, content} when is_binary(content) and content != "" ->
        Logger.info("TurnArtifacts captured understanding.md issue=#{identifier} path=#{path}")

      {:ok, ""} ->
        Logger.debug("TurnArtifacts: understanding.md empty, skipping issue=#{identifier}")

      {:error, reason} ->
        Logger.debug("TurnArtifacts: understanding.md unreadable path=#{path} reason=#{inspect(reason)}")
    end
  end
end
