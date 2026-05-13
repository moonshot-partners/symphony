defmodule SymphonyElixir.GateC do
  @moduledoc """
  Gate C — validates that the agent's first turn-end message conforms to the
  AC Extraction contract in `WORKFLOW.schools-out.md`.

  Pure boundary so the orchestrator stays workflow-agnostic and the rule can
  be exercised in isolation. The orchestrator calls `validate_first_turn/1`
  on `:turn_completed` for the first turn and emits a warning when the
  header is missing.
  """

  require Logger

  @valid_header_pattern ~r/^##\s+(?:AC Extracted|BLOCKED: AC not testable)\b/m

  @typedoc """
  Either `:ok` when the first turn message is conformant, or
  `{:violation, reason :: atom()}` describing the specific violation.
  """
  @type result :: :ok | {:violation, :missing_header | :empty_message}

  @spec validate_first_turn(String.t() | nil) :: result()
  def validate_first_turn(nil), do: {:violation, :empty_message}
  def validate_first_turn(""), do: {:violation, :empty_message}

  def validate_first_turn(text) when is_binary(text) do
    if Regex.match?(@valid_header_pattern, text) do
      :ok
    else
      {:violation, :missing_header}
    end
  end

  @spec log_violation({:violation, atom()}, map()) :: :ok
  def log_violation({:violation, reason}, context) when is_map(context) do
    identifier = Map.get(context, :identifier) || Map.get(context, :issue_identifier) || "(unknown)"

    sample =
      case Map.get(context, :last_agent_text) do
        nil -> "(none)"
        "" -> "(empty)"
        text when is_binary(text) -> text |> String.slice(0, 200)
      end

    Logger.warning(
      "Gate C violation: first turn-end message did not include the required '## AC Extracted' header " <>
        "reason=#{reason} issue_identifier=#{identifier} sample=#{inspect(sample)}"
    )

    :ok
  end
end
