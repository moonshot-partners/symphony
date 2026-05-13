defmodule SymphonyElixir.GitHubPr do
  @moduledoc """
  Checks whether a GitHub pull request still represents "real work product"
  for the purpose of triggering Symphony completion side-effects.

  A PR is considered ACTIVE when it is OPEN or already MERGED. A PR that is
  CLOSED-without-merge is treated as STALE and must not trigger completion
  signals — this guards against abandoned/failed prior PRs (e.g. from older
  agent systems) silently auto-completing a re-opened ticket.

  The default implementation shells out to `gh pr view`. Tests inject a
  pure function via `Application.put_env(:symphony_elixir,
  :pr_active_check_fn, fn url -> boolean end)`.
  """

  require Logger

  @github_pr_regex ~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  @doc """
  Returns true if any of the issue's attached GitHub PR URLs is currently
  OPEN or MERGED. Returns false when every URL is closed-and-not-merged or
  when no URLs can be checked.

  When `gh` cannot answer for a URL (network failure, missing auth), the URL
  is treated as NOT active — the safer default for the completion code path,
  which prefers leaving the agent running over killing it on partial info.
  The failure is logged at error level so operators can detect a stuck `gh`
  rather than silently keeping agents looping forever.
  """
  @spec any_active?(SymphonyElixir.Linear.Issue.t()) :: boolean()
  def any_active?(issue) do
    issue
    |> pr_urls()
    |> Enum.any?(&active?/1)
  end

  @doc """
  Returns true if the URL points to a GitHub PR that is OPEN or merged=true.
  False otherwise (including non-PR URLs and failed lookups).
  """
  @spec active?(String.t() | term()) :: boolean()
  def active?(url) do
    check_fn = Application.get_env(:symphony_elixir, :pr_active_check_fn, &__MODULE__.default_active?/1)
    check_fn.(url)
  end

  @doc false
  @spec default_active?(term()) :: boolean()
  def default_active?(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] ->
        case System.cmd(
               "gh",
               [
                 "pr",
                 "view",
                 number,
                 "--repo",
                 "#{owner}/#{repo}",
                 "--json",
                 "state,merged",
                 "--jq",
                 "[.state, (.merged|tostring)] | @tsv"
               ],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            classify(output)

          {output, code} ->
            Logger.error("gh pr view failed url=#{url} exit_code=#{code} output=#{inspect(output)} — treating PR as NOT active; agent will keep running")
            false
        end

      _ ->
        Logger.warning("default_active?/1 received non-PR URL url=#{inspect(url)}; treating as NOT active")
        false
    end
  end

  def default_active?(other) do
    Logger.warning("default_active?/1 received non-string url=#{inspect(other)}; treating as NOT active")
    false
  end

  @doc false
  @spec classify(String.t()) :: boolean()
  def classify(output) do
    case output |> String.trim() |> String.split("\t") do
      ["OPEN" | _] ->
        true

      [_, "true"] ->
        true

      other ->
        Logger.warning("gh pr view returned unexpected shape parts=#{inspect(other)} raw=#{inspect(output)}; treating as NOT active")
        false
    end
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls(_), do: []
end
