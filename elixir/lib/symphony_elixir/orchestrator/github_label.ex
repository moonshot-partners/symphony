defmodule SymphonyElixir.Orchestrator.GithubLabel do
  @moduledoc """
  Applies the `symphony` label to every GitHub PR attached to a Linear issue.

  Extracted from `SymphonyElixir.Orchestrator` (CP6, "GithubLabel"): pure
  shell-out to `gh`; the only orchestrator-side coupling was `PrUrl.parse/1`,
  already a sibling. No State, no GenServer, no callbacks.
  """

  require Logger
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.PrUrl

  @label_name "symphony"
  @label_color "7C3AED"

  @spec apply(Issue.t() | term()) :: :ok
  def apply(%Issue{repos: repos}) do
    repos
    |> Enum.flat_map(fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
    |> Enum.each(&label_pr/1)

    :ok
  end

  def apply(_), do: :ok

  defp label_pr(pr_url) do
    case PrUrl.parse(pr_url) do
      {:ok, owner, repo, number} ->
        full_repo = "#{owner}/#{repo}"

        case System.cmd(
               "gh",
               ["label", "create", @label_name, "--color", @label_color, "--repo", full_repo],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          {out, _code} when is_binary(out) ->
            handle_label_create_output(out, full_repo)
        end

        case System.cmd(
               "gh",
               ["pr", "edit", "#{number}", "--add-label", @label_name, "--repo", full_repo],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Logger.info("Applied symphony label: #{pr_url}")

          {out, code} ->
            Logger.warning("Failed to apply symphony label to #{pr_url}: exit=#{code} #{String.trim(out)}")
        end

      :error ->
        Logger.warning("Cannot parse GitHub PR URL for labeling: #{inspect(pr_url)}")
    end
  end

  defp handle_label_create_output(out, repo) do
    unless String.contains?(out, "already exists") do
      Logger.warning("gh label create failed for #{repo}: #{String.trim(out)}")
    end
  end
end
