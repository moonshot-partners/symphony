defmodule SymphonyElixir.GitHubPrBody do
  @moduledoc """
  Returns the body markdown of an issue's attached PR(s) via
  `gh pr view --json body`. Sibling of `SymphonyElixir.GitHubPrFiles` —
  extracted so `github_pr.ex` stays under the 600-line cap and so the
  QA-artifact gate (SYM-34) can fetch the body without dragging in the
  `ready?` / `qa_blocked?` machinery.

  Issues with no PR attached short-circuit to `nil` so callers can
  treat "no PR yet" and "fetch failed" uniformly. Tests inject a pure
  function via
  `Application.put_env(:symphony_elixir, :pr_body_fn, fn issue -> body | nil end)`.
  """

  require Logger

  @github_pr_regex ~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  @spec pr_body(SymphonyElixir.Linear.Issue.t() | map()) :: String.t() | nil
  def pr_body(issue) do
    case pr_urls(issue) do
      [] ->
        nil

      _urls ->
        fn_ =
          Application.get_env(
            :symphony_elixir,
            :pr_body_fn,
            &__MODULE__.default_pr_body/1
          )

        fn_.(issue)
    end
  end

  @doc false
  @spec default_pr_body(SymphonyElixir.Linear.Issue.t() | map()) :: String.t() | nil
  def default_pr_body(issue) do
    issue
    |> pr_urls()
    |> Enum.find_value(nil, &fetch_body/1)
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls(_), do: []

  defp fetch_body(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] -> shell_body(owner, repo, number, url)
      _ -> nil
    end
  end

  defp fetch_body(_), do: nil

  defp shell_body(owner, repo, number, url) do
    case System.cmd(
           "gh",
           ["pr", "view", number, "--repo", "#{owner}/#{repo}", "--json", "body", "--jq", ".body"],
           stderr_to_stdout: true
         ) do
      {body, 0} ->
        body

      {output, code} ->
        Logger.debug("gh pr view body failed for #{url} exit=#{code} output=#{inspect(output)}")
        nil
    end
  end
end
