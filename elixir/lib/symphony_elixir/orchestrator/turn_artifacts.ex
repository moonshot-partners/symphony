defmodule SymphonyElixir.Orchestrator.TurnArtifacts do
  @moduledoc """
  After turn 1 completes, discovers `state/*/understanding.md` at any depth
  under the agent workspace via glob and posts its contents as a separate
  Linear comment (threaded under the main workpad comment when available).

  The agent names the state directory after the ticket id, not Symphony's
  session_id, and writes it either at the workspace root or under a repo
  subdir, so the path is discovered by a recursive glob and the
  most-recently-modified match wins when several exist.

  The artifact comment is a fixed, permanent record of the agent's initial
  analysis — independent from the rolling workpad that gets overwritten on
  every turn. This lets the user track the agent's reasoning without being
  limited to the last agent message.

  Pure side-effect: fires an async task and returns `:ok`. Does not mutate
  the running_entry.
  """

  require Logger
  alias SymphonyElixir.Tracker

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

  defp post_understanding_md(workspace_path, issue_id, identifier, parent_id) do
    case discover_understanding_md(workspace_path) do
      nil ->
        Logger.debug("TurnArtifacts: understanding.md not found under #{workspace_path}/**/state/*")

      path ->
        publish_understanding_md(path, issue_id, identifier, parent_id)
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

  defp publish_understanding_md(path, issue_id, identifier, parent_id) do
    case File.read(path) do
      {:ok, content} when is_binary(content) and content != "" ->
        body = "## understanding.md — #{identifier}\n\n#{content}"
        opts = if is_binary(parent_id), do: [parent_id: parent_id], else: []

        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          publish_comment(issue_id, body, opts, identifier)
        end)

        :ok

      {:ok, ""} ->
        Logger.debug("TurnArtifacts: understanding.md empty, skipping issue=#{identifier}")

      {:error, reason} ->
        Logger.debug("TurnArtifacts: understanding.md unreadable path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp publish_comment(issue_id, body, opts, identifier) do
    case Tracker.create_comment(issue_id, body, opts) do
      {:ok, comment_id} ->
        Logger.info("TurnArtifacts posted understanding.md comment=#{comment_id} issue=#{identifier}")

      {:error, reason} ->
        Logger.warning("TurnArtifacts post failed issue=#{identifier} reason=#{inspect(reason)}")
    end
  end
end
