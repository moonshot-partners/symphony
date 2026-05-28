defmodule SymphonyElixir.Orchestrator.ArtifactPin do
  @moduledoc """
  Captures a section of the agent's turn message into the running entry.

  Gate C and Gate D validate the `## AC Extracted` / `## AC Evidence`
  headers against `running_entry.last_agent_text`. Those headers otherwise
  live only in the rolling workpad comment, which is overwritten every
  turn. This module snapshots the section into the persisted running entry
  so downstream gates and the final debug bundle can read it.

  Sourced from the turn text Symphony already holds — no dependency on the
  agent writing a file to a path Symphony has to guess.

  Idempotent per run: each header is captured at most once. `pin/3` returns
  the running entry with the captured header recorded under
  `:pinned_artifacts`; the caller must store that entry back into state so
  the next turn sees the marker. A header already in `:pinned_artifacts`,
  or absent from the turn text, is a no-op — callers can invoke it
  unconditionally on every turn.
  """

  require Logger

  @spec pin(map(), String.t(), String.t()) :: map()
  def pin(running_entry, issue_id, header) do
    if already_pinned?(running_entry, header) do
      running_entry
    else
      case extract_section(Map.get(running_entry, :last_agent_text), header) do
        nil ->
          Logger.debug("ArtifactPin: '#{header}' section not found issue=#{issue_id}")
          running_entry

        section ->
          Logger.info("ArtifactPin captured '#{header}' issue=#{Map.get(running_entry, :identifier, issue_id)}")

          running_entry
          |> mark_pinned(header)
          |> store_section_text(header, section)
      end
    end
  end

  defp store_section_text(running_entry, header, section) do
    current =
      case Map.get(running_entry, :pinned_evidence_text) do
        %{} = m -> m
        _ -> %{}
      end

    Map.put(running_entry, :pinned_evidence_text, Map.put(current, header, section))
  end

  defp already_pinned?(running_entry, header) do
    running_entry |> pinned_set() |> MapSet.member?(header)
  end

  defp pinned_set(running_entry) do
    case Map.get(running_entry, :pinned_artifacts) do
      %MapSet{} = set -> set
      _ -> MapSet.new()
    end
  end

  defp mark_pinned(running_entry, header) do
    Map.put(running_entry, :pinned_artifacts, MapSet.put(pinned_set(running_entry), header))
  end

  defp extract_section(text, _header) when not is_binary(text), do: nil

  defp extract_section(text, header) do
    pattern = ~r/^##[ \t]+#{Regex.escape(header)}\b.*?(?=^##[ \t]|\z)/ms

    case Regex.run(pattern, text) do
      [section] -> String.trim(section)
      nil -> nil
    end
  end
end
