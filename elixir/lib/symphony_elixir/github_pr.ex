defmodule SymphonyElixir.GitHubPr do
  @moduledoc """
  Checks whether a GitHub pull request represents real, ready-to-ship work.

  A PR is READY when either:
    - it is MERGED, or
    - it is OPEN AND `gh pr checks` reports every check green (exit 0).

  `gh pr checks` is invoked without `--required`, which means *all* checks
  (required + optional) must be green for the PR to be considered ready.
  This is intentional: a failing optional check is a real signal an operator
  should see, and the agent re-iterating to fix it is the correct behavior.
  If a repo grows flaky optional checks that produce false negatives, switch
  to `--required` then — don't pre-optimize for a problem that hasn't fired.

  Symphony reads `ready?/1` as the completion signal. An OPEN PR with failing
  or pending checks is NOT ready — the agent must keep working until CI is
  green. This is what catches the SODEV-765-class regression where the agent
  shipped code and walked away while jest tests were broken.

  The default implementation shells out to `gh pr view` (state) and
  `gh pr checks` (CI status). Tests inject a pure function via
  `Application.put_env(:symphony_elixir, :pr_ready_fn, fn url -> boolean end)`.
  """

  require Logger

  @github_pr_regex ~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  @doc """
  Returns true if any of the issue's attached GitHub PRs is ready
  (MERGED, or OPEN with all CI checks green). Returns false otherwise,
  including when no PR URLs are attached.

  When `gh` cannot answer for a URL (network failure, missing auth, pending
  checks), the URL resolves to NOT ready. The agent keeps running on
  partial info rather than auto-completing on a half-finished PR. Failures
  log at error/info level so operators can detect a stuck `gh`.
  """
  @spec ready?(SymphonyElixir.Linear.Issue.t() | map()) :: boolean()
  def ready?(issue) do
    issue
    |> pr_urls()
    |> Enum.any?(&ready_url?/1)
  end

  @doc """
  Returns true if the URL points to a GitHub PR that is currently ready
  (MERGED or OPEN+checks-pass). False otherwise (including non-PR URLs and
  failed lookups).
  """
  @spec ready_url?(String.t() | term()) :: boolean()
  def ready_url?(url) do
    check_fn = Application.get_env(:symphony_elixir, :pr_ready_fn, &__MODULE__.default_ready?/1)
    check_fn.(url)
  end

  @doc false
  @spec default_ready?(term()) :: boolean()
  def default_ready?(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] ->
        ready_from_state?(pr_state(owner, repo, number, url), fn ->
          checks_pass?(owner, repo, number, url)
        end)

      _ ->
        Logger.warning("default_ready?/1 received non-PR URL url=#{inspect(url)}; treating as NOT ready")
        false
    end
  end

  def default_ready?(other) do
    Logger.warning("default_ready?/1 received non-string url=#{inspect(other)}; treating as NOT ready")
    false
  end

  @doc """
  Pure decision function: derives "ready" from a normalized state string and
  a deferred checks-pass thunk. The thunk is only evaluated when state=OPEN
  (avoids an unnecessary `gh pr checks` call for MERGED/CLOSED PRs).
  """
  @spec ready_from_state?(String.t(), (-> boolean()) | boolean()) :: boolean()
  def ready_from_state?("MERGED", _), do: true

  def ready_from_state?("OPEN", checks_fn) when is_function(checks_fn, 0) do
    checks_fn.()
  end

  def ready_from_state?("OPEN", checks) when is_boolean(checks), do: checks

  def ready_from_state?(state, _) do
    Logger.debug("ready_from_state?/2 treating state=#{inspect(state)} as NOT ready")
    false
  end

  @doc """
  Pure: parses raw `gh pr view --jq '.state'` output. Trims whitespace.
  Unknown states pass through verbatim (caller treats them as not-ready).
  """
  @spec parse_state(String.t()) :: String.t()
  def parse_state(output) when is_binary(output), do: String.trim(output)

  defp pr_state(owner, repo, number, url) do
    case System.cmd(
           "gh",
           [
             "pr",
             "view",
             number,
             "--repo",
             "#{owner}/#{repo}",
             "--json",
             "state",
             "--jq",
             ".state"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_state(output)

      {output, code} ->
        Logger.error("gh pr view failed url=#{url} exit_code=#{code} output=#{inspect(output)} — treating PR as NOT ready; agent will keep running")
        "_unknown"
    end
  end

  defp checks_pass?(owner, repo, number, url) do
    case System.cmd(
           "gh",
           ["pr", "checks", number, "--repo", "#{owner}/#{repo}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        true

      {output, 8} ->
        Logger.debug("gh pr checks pending for #{owner}/#{repo}##{number} (#{url}) output=#{inspect(output)} — agent will keep working")
        false

      {output, code} ->
        Logger.warning("gh pr checks FAILED for #{owner}/#{repo}##{number} (#{url}) exit_code=#{code} output=#{inspect(output)} — treating PR as NOT ready")
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
