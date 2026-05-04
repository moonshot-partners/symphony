defmodule SymphonyElixir.Agent.DevflowContext do
  @moduledoc """
  Builds the optional `devflowContext` map sent on `thread/start` so the shim
  can activate devflow-agent guardrails for unattended runs.

  Activation is opt-in via `SYMPHONY_DEVFLOW_ROOT`. When the env var is unset,
  `from_issue_and_env/1` returns `nil` and the shim keeps its current
  behaviour bit-for-bit. When the env var is set, the returned map carries
  the issue identity + policy the shim forwards to `compose_devflow_bundle/1`.
  """

  alias SymphonyElixir.Linear.Issue

  @valid_policies ~w(auto_deny log_and_allow escalate)

  @spec from_issue_and_env(Issue.t()) :: map() | nil
  def from_issue_and_env(%Issue{} = issue) do
    case System.get_env("SYMPHONY_DEVFLOW_ROOT") do
      nil ->
        nil

      "" ->
        nil

      root ->
        %{
          "devflowRoot" => root,
          "issueIdentifier" => to_string_or_empty(issue.identifier),
          "issueTitle" => to_string_or_empty(issue.title),
          "issueUrl" => to_string_or_empty(issue.url),
          "policy" => resolve_policy(),
          "basePrompt" => System.get_env("SYMPHONY_DEVFLOW_BASE_PROMPT", "")
        }
    end
  end

  defp resolve_policy do
    case System.get_env("SYMPHONY_DEVFLOW_POLICY", "auto_deny") do
      policy when policy in @valid_policies ->
        policy

      other ->
        raise ArgumentError,
              "SYMPHONY_DEVFLOW_POLICY=#{inspect(other)} is invalid; expected one of #{Enum.join(@valid_policies, ", ")}"
    end
  end

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(value), do: to_string(value)
end
