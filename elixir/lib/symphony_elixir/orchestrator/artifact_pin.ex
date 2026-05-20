defmodule SymphonyElixir.Orchestrator.ArtifactPin do
  @moduledoc """
  Pins a section of the agent's turn message as a fixed tracker comment.

  Gate C and Gate D validate the `## AC Extracted` / `## AC Evidence`
  headers against `running_entry.last_agent_text`. Those headers otherwise
  live only in the rolling workpad comment, which is overwritten every
  turn. This module snapshots the section into a permanent comment,
  threaded under the workpad comment when available.

  Sourced from the turn text Symphony already holds — no dependency on the
  agent writing a file to a path Symphony has to guess.

  Pure side-effect: fires an async task and returns `:ok`. No-op when the
  header is absent, so callers can invoke it unconditionally.
  """

  require Logger
  alias SymphonyElixir.Tracker

  @spec pin(map(), String.t(), String.t()) :: :ok
  def pin(running_entry, issue_id, header) do
    case extract_section(Map.get(running_entry, :last_agent_text), header) do
      nil ->
        Logger.debug("ArtifactPin: '#{header}' section not found issue=#{issue_id}")

      section ->
        publish(section, header, running_entry, issue_id)
    end

    :ok
  end

  defp extract_section(text, _header) when not is_binary(text), do: nil

  defp extract_section(text, header) do
    pattern = ~r/^##[ \t]+#{Regex.escape(header)}\b.*?(?=^##[ \t]|\z)/ms

    case Regex.run(pattern, text) do
      [section] -> String.trim(section)
      nil -> nil
    end
  end

  defp publish(section, header, running_entry, issue_id) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    parent_id = Map.get(running_entry, :workpad_comment_id)
    opts = if is_binary(parent_id), do: [parent_id: parent_id], else: []

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      publish_comment(issue_id, section, opts, header, identifier)
    end)

    :ok
  end

  defp publish_comment(issue_id, body, opts, header, identifier) do
    case Tracker.create_comment(issue_id, body, opts) do
      {:ok, comment_id} ->
        Logger.info("ArtifactPin posted '#{header}' comment=#{comment_id} issue=#{identifier}")

      {:error, reason} ->
        Logger.warning("ArtifactPin post failed header='#{header}' issue=#{identifier} reason=#{inspect(reason)}")
    end
  end
end
