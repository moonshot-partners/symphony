defmodule SymphonyElixir.Cockpit.Checks do
  @moduledoc """
  Read-only CI status for a PR, for the cockpit board. Shells `gh pr view` and
  reuses the orchestrator's `ChecksClassifier` so the board agrees with the
  agent's own CI verdict. Fail-soft: any error returns nil (unknown), never
  raises into the board build. Calls are bounded by the board cache, so an open
  cockpit does not exhaust the shared GitHub budget.
  """

  alias SymphonyElixir.GitHubPr.ChecksClassifier

  @spec status(String.t() | nil) :: String.t() | nil
  def status(url) when is_binary(url) and url != "" do
    case System.cmd("gh", ["pr", "view", url, "--json", "state,statusCheckRollup"], stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, payload} -> classify(ChecksClassifier.classify_pr_view_payload(payload))
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def status(_), do: nil

  defp classify(:all_green), do: "passing"
  defp classify(:pending), do: "pending"
  defp classify({:red, _}), do: "failing"
  defp classify(_), do: nil
end
