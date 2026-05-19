defmodule SymphonyElixir.Orchestrator.TurnArtifacts do
  @moduledoc """
  After turn 1 completes, reads `state/<session_id>/understanding.md` from
  the agent workspace and posts its contents as a separate Linear comment
  (threaded under the main workpad comment when available).

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
         session_id when is_binary(session_id) <- Map.get(running_entry, :session_id),
         workspace_path when is_binary(workspace_path) <- Map.get(running_entry, :workspace_path) do
      parent_id = Map.get(running_entry, :workpad_comment_id)
      identifier = Map.get(running_entry, :identifier, issue_id)
      post_understanding_md(workspace_path, session_id, issue_id, identifier, parent_id)
    end

    :ok
  end

  def maybe_post(_running_entry, _update, _issue_id), do: :ok

  defp post_understanding_md(workspace_path, session_id, issue_id, identifier, parent_id) do
    path = Path.join([workspace_path, "state", session_id, "understanding.md"])

    case File.read(path) do
      {:ok, content} when is_binary(content) and content != "" ->
        body = "## understanding.md — #{identifier}\n\n#{content}"
        opts = if is_binary(parent_id), do: [parent_id: parent_id], else: []

        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          case Tracker.create_comment(issue_id, body, opts) do
            {:ok, comment_id} ->
              Logger.info("TurnArtifacts posted understanding.md comment=#{comment_id} issue=#{identifier}")

            {:error, reason} ->
              Logger.warning("TurnArtifacts post failed issue=#{identifier} reason=#{inspect(reason)}")
          end
        end)

        :ok

      {:ok, ""} ->
        Logger.debug("TurnArtifacts: understanding.md empty, skipping issue=#{identifier}")

      {:error, reason} ->
        Logger.debug("TurnArtifacts: understanding.md not found path=#{path} reason=#{inspect(reason)}")
    end
  end
end
