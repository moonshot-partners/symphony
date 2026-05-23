defmodule SymphonyElixir.GitHubPrFiles do
  @moduledoc """
  Returns the list of files changed by an issue's PR(s), per
  `gh pr view --json files`. Sibling of `SymphonyElixir.GitHubPr` —
  extracted so `github_pr.ex` stays under the 600-line cap.

  Issues with no PR attached short-circuit to `[]` so the conflict-disclosure
  gate (SYM-30) can run uniformly. Tests inject a pure function via
  `Application.put_env(:symphony_elixir, :pr_changed_files_fn, fn issue -> [paths] end)`.
  """

  require Logger

  @github_pr_regex ~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  @spec changed_files(SymphonyElixir.Linear.Issue.t() | map()) :: [String.t()]
  def changed_files(issue) do
    case pr_urls(issue) do
      [] ->
        []

      _urls ->
        fn_ =
          Application.get_env(
            :symphony_elixir,
            :pr_changed_files_fn,
            &__MODULE__.default_changed_files/1
          )

        fn_.(issue)
    end
  end

  @doc false
  @spec default_changed_files(SymphonyElixir.Linear.Issue.t() | map()) :: [String.t()]
  def default_changed_files(issue) do
    issue
    |> pr_urls()
    |> Enum.flat_map(&fetch_changed_files/1)
    |> Enum.uniq()
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls(_), do: []

  # `pr_urls/1` already filters to binary urls, so this clause never sees a non-binary.
  defp fetch_changed_files(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] -> shell_changed_files(owner, repo, number, url)
      _ -> []
    end
  end

  defp shell_changed_files(owner, repo, number, url) do
    case System.cmd(
           "gh",
           [
             "pr",
             "view",
             number,
             "--repo",
             "#{owner}/#{repo}",
             "--json",
             "files",
             "--jq",
             ".files[].path"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {output, code} ->
        Logger.debug("gh pr view files failed for #{url} exit=#{code} output=#{inspect(output)}")

        []
    end
  end
end
