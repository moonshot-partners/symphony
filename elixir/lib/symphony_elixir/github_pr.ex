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

  alias SymphonyElixir.GitHubPr.ChecksClassifier
  alias SymphonyElixir.GitHubPr.ReviewVerdict

  @github_pr_regex ~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  @doc """
  Close every GitHub PR attached to an issue and ask GitHub to delete each
  source branch. Used by destructive cockpit reruns.

  Failures are returned per URL so callers can keep the rerun moving while
  surfacing exactly what did not get cleaned up.
  """
  @spec close_for_issue(SymphonyElixir.Linear.Issue.t() | map()) :: %{
          closed: [String.t()],
          failed: [map()],
          skipped: [String.t()]
        }
  def close_for_issue(issue) do
    issue
    |> pr_urls()
    |> Enum.reduce(%{closed: [], failed: [], skipped: []}, fn url, acc ->
      case close_url(url) do
        :ok -> Map.update!(acc, :closed, &[url | &1])
        {:skip, reason} -> Map.update!(acc, :skipped, &["#{url}: #{reason}" | &1])
        {:error, reason} -> Map.update!(acc, :failed, &[%{url: url, reason: inspect(reason)} | &1])
      end
    end)
    |> Map.update!(:closed, &Enum.reverse/1)
    |> Map.update!(:failed, &Enum.reverse/1)
    |> Map.update!(:skipped, &Enum.reverse/1)
  end

  defp close_url(url) when is_binary(url) do
    close_fn = Application.get_env(:symphony_elixir, :pr_close_fn, &__MODULE__.default_close_url/1)
    close_fn.(url)
  end

  @doc false
  @spec default_close_url(String.t()) :: :ok | {:skip, atom()} | {:error, term()}
  def default_close_url(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] ->
        case System.cmd(
               "gh",
               ["pr", "close", number, "--repo", "#{owner}/#{repo}", "--delete-branch"],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, code} -> {:error, %{exit_code: code, output: output}}
        end

      _ ->
        {:skip, :not_github_pr_url}
    end
  end

  @doc """
  Returns true only when every attached GitHub PR is ready (MERGED, or OPEN
  with all CI checks green). Returns false otherwise, including when no PR
  URLs are attached.

  Multi-repo issues are not complete until every attached PR is ready. Treating
  "any ready PR" as complete lets a green backend PR mask a pending frontend PR,
  which can stop the agent before the actual changed repo clears review/CI.

  When `gh` cannot answer for a URL (network failure, missing auth, pending
  checks), the URL resolves to NOT ready. The agent keeps running on
  partial info rather than auto-completing on a half-finished PR. Failures
  log at error/info level so operators can detect a stuck `gh`.
  """
  @spec ready?(SymphonyElixir.Linear.Issue.t() | map()) :: boolean()
  def ready?(issue) do
    case pr_urls(issue) do
      [] -> false
      urls -> Enum.all?(urls, &ready_url?/1)
    end
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

  @doc """
  Returns true when every attached GitHub PR is settled — MERGED or CLOSED —
  so the SYM-16 re-engagement loop can evict the issue from `state.completed`
  and stop re-scanning it every poll cycle. Returns false when any PR is still
  OPEN, when `gh` cannot answer (treated as still-open, fail-safe toward keeping
  the watch), or when no PR urls are attached.

  Tests inject a pure function via
  `Application.put_env(:symphony_elixir, :pr_merged_or_closed_fn, fn issue -> bool end)`.
  """
  @spec pr_merged_or_closed?(SymphonyElixir.Linear.Issue.t() | map()) :: boolean()
  def pr_merged_or_closed?(issue) do
    check_fn =
      Application.get_env(
        :symphony_elixir,
        :pr_merged_or_closed_fn,
        &__MODULE__.default_pr_merged_or_closed?/1
      )

    check_fn.(issue)
  end

  @doc false
  @spec default_pr_merged_or_closed?(SymphonyElixir.Linear.Issue.t() | map()) :: boolean()
  def default_pr_merged_or_closed?(issue) do
    case pr_urls(issue) do
      [] -> false
      urls -> Enum.all?(urls, &settled_url?/1)
    end
  end

  @doc """
  Pure: a PR state string is "settled" (re-engagement can never fire again)
  when it is MERGED or CLOSED. OPEN, unknown, and error states are not settled,
  so the re-engagement watch is kept.
  """
  @spec settled_state?(term()) :: boolean()
  def settled_state?(state) when is_binary(state), do: state in ["MERGED", "CLOSED"]
  def settled_state?(_), do: false

  defp settled_url?(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] -> settled_state?(pr_state(owner, repo, number, url))
      _ -> false
    end
  end

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

  @doc """
  Returns true if the issue's open PR body contains `- Result: BLOCKED`,
  indicating the agent's QA self-review was blocked (e.g. staging auth failure).

  The default implementation shells out to `gh pr view`. Tests inject a pure
  function via `Application.put_env(:symphony_elixir, :pr_qa_blocked_fn, fn issue -> bool end)`.
  """
  @spec qa_blocked?(SymphonyElixir.Linear.Issue.t() | map()) :: boolean()
  def qa_blocked?(issue) do
    check_fn =
      Application.get_env(:symphony_elixir, :pr_qa_blocked_fn, &__MODULE__.default_qa_blocked?/1)

    check_fn.(issue)
  end

  @doc false
  @spec default_qa_blocked?(SymphonyElixir.Linear.Issue.t() | map()) :: boolean()
  def default_qa_blocked?(issue) do
    issue
    |> pr_urls()
    |> Enum.any?(&body_blocked?/1)
  end

  @doc """
  Pure predicate: returns true if the PR body string contains a `- Result: BLOCKED` line.
  """
  @spec parse_qa_blocked?(String.t() | nil) :: boolean()
  def parse_qa_blocked?(nil), do: false

  def parse_qa_blocked?(body) when is_binary(body) do
    String.contains?(body, "- Result: BLOCKED")
  end

  defp body_blocked?(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] ->
        case System.cmd(
               "gh",
               ["pr", "view", number, "--repo", "#{owner}/#{repo}", "--json", "body", "--jq", ".body"],
               stderr_to_stdout: true
             ) do
          {body, 0} -> parse_qa_blocked?(body)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp body_blocked?(_), do: false

  @typedoc """
  Result of a critical-review detection pass against a PR.

  `{:critical, info}` carries the `count`, `items`, and `head_sha` so the
  caller can dedup auto-engagement attempts by `(pr_url, commit_sha)` per
  SYM-16 §3.3 and post a meaningful workpad comment.

  Historical name note: this covers any fresh blocking PR-review verdict. Some
  `claude-pr-review` runs report `Critical Issues (0)` but still use the
  blocking verdict for important issues; `scope-discipline: FAIL` comments are
  also blocking until a fresher PASS or a new commit clears them.
  """
  @type critical_review_result ::
          {:critical, %{count: non_neg_integer(), items: [String.t()], head_sha: String.t()}}
          | :none

  @doc """
  Returns `{:critical, %{count: n, items: list, head_sha: sha}}` when the latest
  blocking PR-review verdict comment on any of the issue's PRs is fresher than
  the PR's HEAD commit. Returns `:none` otherwise (including when no PR is
  attached, the latest verdict is clear/pass, or the verdict predates the
  current HEAD — i.e. a new commit was pushed since the review ran).

  Tests inject a pure function via
  `Application.put_env(:symphony_elixir, :pr_critical_review_fn, fn issue -> result end)`.

  See `critical_review_from_comments/3` for the pure decision boundary and
  `parse_critical_review_body/1` for the body-string parser.
  """
  @spec critical_review_pending?(SymphonyElixir.Linear.Issue.t() | map()) ::
          critical_review_result()
  def critical_review_pending?(issue) do
    case pr_urls(issue) do
      [] ->
        :none

      _urls ->
        check_fn =
          Application.get_env(
            :symphony_elixir,
            :pr_critical_review_fn,
            &__MODULE__.default_critical_review_pending?/1
          )

        check_fn.(issue)
    end
  end

  @doc false
  @spec default_critical_review_pending?(SymphonyElixir.Linear.Issue.t() | map()) ::
          critical_review_result()
  def default_critical_review_pending?(issue) do
    issue
    |> pr_urls()
    |> Enum.find_value(:none, fn url ->
      case detect_critical_review_for_url(url) do
        :none -> false
        {:critical, info} -> {:critical, Map.put_new(info, :pr_url, url)}
      end
    end)
  end

  defp detect_critical_review_for_url(url) when is_binary(url) do
    with [_, owner, repo, number] <- Regex.run(@github_pr_regex, url),
         {:ok, head_sha, head_at, "OPEN"} <- fetch_head_meta(owner, repo, number, url),
         {:ok, comments} <- fetch_pr_comments(owner, repo, number, url) do
      case fetch_pr_review_verdict(owner, repo, number, url) do
        {:ok, verdict} -> critical_review_from_structured_verdict(verdict, head_sha)
        :missing -> critical_review_from_comments(comments, head_sha, head_at)
        {:error, reason} -> unknown_review_result(head_sha, "artifact read failed: #{inspect(reason)}")
      end
    else
      # A non-OPEN PR (CLOSED/MERGED) carries no actionable review: a stale
      # request_changes comment on a closed PR must NOT re-engage the agent
      # (it would re-attach the dead PR to the ticket). Treat as :none.
      _ -> :none
    end
  end

  defp detect_critical_review_for_url(_), do: :none

  defp fetch_pr_review_verdict(owner, repo, number, url) do
    fetch_fn =
      Application.get_env(
        :symphony_elixir,
        :pr_review_verdict_artifact_fn,
        &__MODULE__.default_fetch_pr_review_verdict/4
      )

    fetch_fn.(owner, repo, number, url)
  end

  @doc false
  @spec default_fetch_pr_review_verdict(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | :missing | {:error, term()}
  def default_fetch_pr_review_verdict(owner, repo, number, url) do
    with {:ok, rollup} <- fetch_status_rollup_entries(owner, repo, number, url),
         {:ok, run_id} <- review_workflow_run_id(rollup),
         {:ok, artifact_id} <- review_verdict_artifact_id(owner, repo, run_id),
         {:ok, payload} <- download_review_verdict_artifact(owner, repo, artifact_id) do
      {:ok, payload}
    else
      :missing -> :missing
      {:error, reason} when reason in [:artifact_download_failed, :malformed_artifact_zip] -> {:error, reason}
      {:error, _} -> :missing
    end
  end

  defp fetch_status_rollup_entries(owner, repo, number, url) do
    case System.cmd(
           "gh",
           ["pr", "view", number, "--repo", "#{owner}/#{repo}", "--json", "statusCheckRollup"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"statusCheckRollup" => entries}} when is_list(entries) -> {:ok, entries}
          _ -> {:error, :malformed_status_rollup}
        end

      {output, code} ->
        Logger.debug("gh pr view statusCheckRollup failed for review verdict #{url} exit=#{code} output=#{inspect(output)}")
        {:error, :status_rollup_failed}
    end
  end

  defp review_workflow_run_id(entries) do
    entries
    |> Enum.filter(&review_check_run?/1)
    |> Enum.sort_by(&check_started_at/1, :desc)
    |> Enum.find_value(:missing, &run_id_from_details_url/1)
    |> case do
      :missing -> :missing
      run_id -> {:ok, run_id}
    end
  end

  defp review_check_run?(entry) when is_map(entry) do
    check_name = String.downcase(to_string(entry["name"] || entry["context"] || ""))
    workflow_name = String.downcase(to_string(entry["workflowName"] || entry["workflow_name"] || ""))

    String.contains?(check_name, "claude-pr-review") or
      String.contains?(workflow_name, "claude-pr-review")
  end

  defp review_check_run?(_), do: false

  defp check_started_at(%{"startedAt" => at}) when is_binary(at), do: at
  defp check_started_at(%{"started_at" => at}) when is_binary(at), do: at
  defp check_started_at(_), do: ""

  defp run_id_from_details_url(%{"detailsUrl" => url}) when is_binary(url) do
    parse_workflow_run_id(url)
  end

  defp run_id_from_details_url(%{"details_url" => url}) when is_binary(url) do
    parse_workflow_run_id(url)
  end

  defp run_id_from_details_url(_), do: false

  defp parse_workflow_run_id(url) do
    case Regex.run(~r{/actions/runs/(\d+)}, url) do
      [_, run_id] -> run_id
      _ -> false
    end
  end

  defp review_verdict_artifact_id(owner, repo, run_id) do
    path = "/repos/#{owner}/#{repo}/actions/runs/#{run_id}/artifacts?name=claude-pr-review-verdict"

    case System.cmd("gh", ["api", path], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"artifacts" => [%{"id" => artifact_id} | _]}} -> {:ok, to_string(artifact_id)}
          {:ok, %{"artifacts" => []}} -> :missing
          _ -> {:error, :malformed_artifact_list}
        end

      {output, code} ->
        Logger.debug("gh api artifact list failed for #{owner}/#{repo} run=#{run_id} exit=#{code} output=#{inspect(output)}")
        {:error, :artifact_list_failed}
    end
  end

  defp download_review_verdict_artifact(owner, repo, artifact_id) do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-review-verdict-#{System.unique_integer([:positive])}")
    zip_path = Path.join(tmp_dir, "artifact.zip")

    try do
      with :ok <- File.mkdir_p(tmp_dir),
           {_, 0} <-
             System.cmd(
               "gh",
               [
                 "api",
                 "/repos/#{owner}/#{repo}/actions/artifacts/#{artifact_id}/zip",
                 "--output",
                 zip_path
               ],
               stderr_to_stdout: true
             ),
           {:ok, _files} <- :zip.extract(String.to_charlist(zip_path), cwd: String.to_charlist(tmp_dir)),
           {:ok, json} <- File.read(Path.join(tmp_dir, "claude-pr-review-verdict.json")),
           {:ok, payload} <- Jason.decode(json) do
        {:ok, payload}
      else
        {output, code} when is_integer(code) ->
          Logger.debug("gh api artifact download failed for #{owner}/#{repo} artifact=#{artifact_id} exit=#{code} output=#{inspect(output)}")
          {:error, :artifact_download_failed}

        {:error, _reason} ->
          {:error, :malformed_artifact_zip}
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp fetch_head_meta(owner, repo, number, url) do
    fetch_fn =
      Application.get_env(
        :symphony_elixir,
        :pr_head_meta_fn,
        &__MODULE__.default_fetch_head_meta/4
      )

    fetch_fn.(owner, repo, number, url)
  end

  @doc false
  @spec default_fetch_head_meta(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t(), DateTime.t() | nil, String.t()} | :error
  def default_fetch_head_meta(owner, repo, number, url) do
    case System.cmd(
           "gh",
           [
             "pr",
             "view",
             number,
             "--repo",
             "#{owner}/#{repo}",
             "--json",
             "headRefOid,commits,state",
             "--jq",
             "{head: .headRefOid, committed_at: (.commits | last.committedDate), state: .state}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"head" => head, "committed_at" => at} = meta} when is_binary(head) ->
            {:ok, head, parse_committed_at(at), normalize_pr_state(meta["state"])}

          _ ->
            Logger.debug("gh pr view returned no head meta for #{url} output=#{inspect(output)}")

            :error
        end

      {output, code} ->
        Logger.debug("gh pr view failed for #{url} exit=#{code} output=#{inspect(output)}")
        :error
    end
  end

  # Defaults to "OPEN" when the state field is absent so detection stays
  # fail-open: only an explicit CLOSED/MERGED short-circuits re-engagement.
  defp normalize_pr_state(state) when is_binary(state), do: state |> String.trim() |> String.upcase()
  defp normalize_pr_state(_), do: "OPEN"

  defp parse_committed_at(nil), do: nil

  defp parse_committed_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp fetch_pr_comments(owner, repo, number, url) do
    fetch_fn =
      Application.get_env(
        :symphony_elixir,
        :pr_comments_fn,
        &__MODULE__.default_fetch_pr_comments/4
      )

    fetch_fn.(owner, repo, number, url)
  end

  @doc false
  @spec default_fetch_pr_comments(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | :error
  def default_fetch_pr_comments(owner, repo, number, url) do
    case System.cmd(
           "gh",
           ["api", "/repos/#{owner}/#{repo}/issues/#{number}/comments"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> :error
        end

      {output, code} ->
        Logger.debug("gh api comments failed for #{url} exit=#{code} output=#{inspect(output)}")

        :error
    end
  end

  @doc """
  Pure decision over a list of PR comments. Returns `{:critical, info}` when
  the most-recent workflow-bot verdict comment is blocking and was posted
  at/after `head_committed_at` (or when `head_committed_at` is nil — a
  conservative fallback that prefers flagging over silence). Returns `:none`
  otherwise.

  Comments are expected to be a list of maps with `"body"` plus a GitHub
  timestamp key (`"created_at"`, `"createdAt"`, or `"submittedAt"`).
  Comments whose body does NOT contain a known verdict prefix are ignored; the
  latest matching verdict wins (an `approve` or `PASS` posted after a failure
  correctly clears the alarm).
  """
  @spec critical_review_from_comments([map()], String.t(), DateTime.t() | nil) ::
          critical_review_result()
  def critical_review_from_comments(comments, head_sha, head_committed_at)
      when is_list(comments) and is_binary(head_sha) do
    comments
    |> Enum.filter(&verdict_comment?/1)
    |> Enum.sort_by(&comment_created_at/1, {:desc, DateTime})
    |> Enum.find_value(:none, &critical_review_from_comment(&1, head_sha, head_committed_at))
  end

  def critical_review_from_comments(_, _, _), do: :none

  @doc """
  Pure decision over a decoded `claude-pr-review-verdict.json` artifact.

  A present artifact is authoritative. Malformed, stale, or internally
  inconsistent artifacts map to a blocking `unknown` result; only a missing
  artifact falls back to PR comment parsing at the caller.
  """
  @spec critical_review_from_structured_verdict(map() | term(), String.t()) ::
          critical_review_result()
  def critical_review_from_structured_verdict(payload, head_sha) when is_binary(head_sha) do
    case ReviewVerdict.evaluate(payload, head_sha) do
      {:blocking, info} -> {:critical, info}
      {:unknown, reason} -> unknown_review_result(head_sha, reason)
      :clear -> :none
    end
  end

  def critical_review_from_structured_verdict(_, _), do: :none

  defp unknown_review_result(head_sha, reason) do
    {:critical,
     %{
       count: 0,
       items: ["claude-pr-review structured verdict is unknown: #{reason}"],
       head_sha: head_sha
     }}
  end

  defp critical_review_from_comment(comment, head_sha, head_committed_at) do
    if fresh_enough?(comment, head_committed_at) do
      case parse_critical_review_body(comment["body"]) do
        {:request_changes, count, items} ->
          {:critical, %{count: count, items: items, head_sha: head_sha}}

        :none ->
          # Latest verdict explicitly clears the alarm (approve / comment / pass).
          :none
      end
    end
  end

  defp verdict_comment?(%{"body" => body}) when is_binary(body) do
    String.contains?(body, "# claude-pr-review:") or
      String.contains?(body, "scope-discipline:")
  end

  defp verdict_comment?(_), do: false

  defp comment_created_at(comment) when is_map(comment) do
    at = comment["created_at"] || comment["createdAt"] || comment["submittedAt"]

    parse_comment_created_at(at)
  end

  defp comment_created_at(_), do: ~U[1970-01-01 00:00:00Z]

  defp parse_comment_created_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp parse_comment_created_at(_), do: ~U[1970-01-01 00:00:00Z]

  defp fresh_enough?(_comment, nil), do: true

  defp fresh_enough?(comment, %DateTime{} = head_at) do
    DateTime.compare(comment_created_at(comment), head_at) != :lt
  end

  @doc """
  Pure parser: extracts the `claude-pr-review` verdict + Critical Issues count
  from a comment body. Returns `{:request_changes, count, items}` when the
  verdict is `request_changes`, including `Critical Issues (0)`. Returns
  `:none` for every other shape (nil body, no header, `approve`, `comment`).
  """
  @spec parse_critical_review_body(String.t() | nil) ::
          {:request_changes, non_neg_integer(), [String.t()]} | :none
  def parse_critical_review_body(nil), do: :none
  def parse_critical_review_body(""), do: :none

  def parse_critical_review_body(body) when is_binary(body) do
    parse_claude_pr_review_body(body) || parse_scope_discipline_body(body) || :none
  end

  defp parse_claude_pr_review_body(body) do
    with [_, verdict] <- Regex.run(~r/^# claude-pr-review:\s*(\w+)/m, body),
         "request_changes" <- verdict,
         [_, count_str] <- Regex.run(~r/^##\s+Critical Issues\s+\((\d+)\)/m, body),
         {count, ""} <- Integer.parse(count_str) do
      {:request_changes, count, extract_critical_items(body)}
    else
      _ -> nil
    end
  end

  defp parse_scope_discipline_body(body) do
    with [_, count_str] <- Regex.run(~r/^scope-discipline:\s*FAIL\s*-\s*(\d+)\s+violation/m, body),
         {count, ""} when count > 0 <- Integer.parse(count_str) do
      {:request_changes, count, extract_scope_discipline_items(body)}
    else
      _ -> nil
    end
  end

  defp extract_critical_items(body) do
    # Take the slice from `## Critical Issues (N)` to the next `## ` heading and
    # pull out the bullet lines. Mirrors how the pr-review-toolkit formats its
    # output (see claude-pr-review.yml in fe-next-app / schools-out).
    case Regex.run(~r/^##\s+Critical Issues\s+\(\d+\)\n(.*?)(?:\n##\s|\z)/sm, body) do
      [_, block] ->
        block
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "- "))

      _ ->
        []
    end
  end

  defp extract_scope_discipline_items(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "- "))
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls(_), do: []

  @typedoc """
  Decision verdict for `required_checks_status/1` (SYM-1c / SYM-29).

  * `:all_green`  — every check completed with SUCCESS / NEUTRAL / SKIPPED / STALE.
  * `{:red, [name]}` — at least one check failed; payload lists the failing names
    in the order returned by GitHub (used by the orchestrator's reject-state
    comment).
  * `:pending` — no failures yet but at least one check is still running.
  """
  @type required_checks_status :: :all_green | {:red, [String.t()]} | :pending

  @doc """
  Returns the CI verdict for the issue's PR(s) per `gh pr view --json statusCheckRollup`.

  When multiple PRs are attached, the verdict is the worst case (any red → red,
  else any pending → pending, else all green). Issues with no PR attached
  short-circuit to `:all_green` so callers can apply this gate uniformly.

  Tests inject a pure function via
  `Application.put_env(:symphony_elixir, :pr_required_checks_status_fn, fn issue -> verdict end)`.
  """
  @spec required_checks_status(SymphonyElixir.Linear.Issue.t() | map()) :: required_checks_status()
  def required_checks_status(issue) do
    case pr_urls(issue) do
      [] ->
        :all_green

      _urls ->
        check_fn =
          Application.get_env(
            :symphony_elixir,
            :pr_required_checks_status_fn,
            &__MODULE__.default_required_checks_status/1
          )

        check_fn.(issue)
    end
  end

  @doc false
  @spec default_required_checks_status(SymphonyElixir.Linear.Issue.t() | map()) ::
          required_checks_status()
  def default_required_checks_status(issue) do
    issue
    |> pr_urls()
    |> Enum.reduce(:all_green, &combine_status(&1, &2))
  end

  defp combine_status(_url, {:red, _} = red), do: red

  defp combine_status(url, acc) do
    case fetch_status_check_rollup(url) do
      {:red, _} = red -> red
      :pending -> :pending
      :all_green -> acc
    end
  end

  defp fetch_status_check_rollup(url) when is_binary(url) do
    case Regex.run(@github_pr_regex, url) do
      [_, owner, repo, number] -> shell_status_check_rollup(owner, repo, number, url)
      _ -> :all_green
    end
  end

  defp fetch_status_check_rollup(_), do: :all_green

  defp shell_status_check_rollup(owner, repo, number, url) do
    case System.cmd(
           "gh",
           ["pr", "view", number, "--repo", "#{owner}/#{repo}", "--json", "state,statusCheckRollup"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, payload} ->
            ChecksClassifier.classify_pr_view_payload(payload)

          _ ->
            Logger.debug("required_checks_status: malformed rollup for #{url} output=#{inspect(output)}")
            :all_green
        end

      {output, code} ->
        Logger.debug("gh pr view statusCheckRollup failed for #{url} exit=#{code} output=#{inspect(output)}")
        :all_green
    end
  end
end
