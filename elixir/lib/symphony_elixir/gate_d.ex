defmodule SymphonyElixir.GateD do
  @moduledoc """
  Gate D — validates that the agent's final turn message contains an
  `## AC Evidence` section mapping each acceptance criterion to the
  specific code or test that satisfies it.

  Pure boundary so the orchestrator stays workflow-agnostic and the
  rule can be exercised in isolation. The orchestrator calls
  `validate_final_turn/1` after a session ends with `:normal` exit.
  """

  require Logger

  @valid_header_pattern ~r/^##\s+(?:AC Evidence\b|BLOCKED:)/m

  @typedoc """
  `:ok` when the final turn is conformant, or
  `{:violation, reason}` describing the specific violation.
  """
  @type result :: :ok | {:violation, :missing_header | :empty_message}

  @spec validate_final_turn(String.t() | nil) :: result()
  def validate_final_turn(nil), do: {:violation, :empty_message}
  def validate_final_turn(""), do: {:violation, :empty_message}

  def validate_final_turn(text) when is_binary(text) do
    if Regex.match?(@valid_header_pattern, text) do
      :ok
    else
      {:violation, :missing_header}
    end
  end

  @spec log_violation({:violation, atom()}, map()) :: :ok
  def log_violation({:violation, reason}, context) when is_map(context) do
    identifier =
      Map.get(context, :identifier) || Map.get(context, :issue_identifier) || "(unknown)"

    sample =
      case Map.get(context, :last_agent_text) do
        nil -> "(none)"
        "" -> "(empty)"
        text when is_binary(text) -> String.slice(text, 0, 200)
      end

    Logger.warning(
      "Gate D violation: final turn message did not include the required '## AC Evidence' header " <>
        "reason=#{reason} issue_identifier=#{identifier} sample=#{inspect(sample)}"
    )

    :ok
  end
end
