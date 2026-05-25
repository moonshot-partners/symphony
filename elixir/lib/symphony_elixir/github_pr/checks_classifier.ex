defmodule SymphonyElixir.GitHubPr.ChecksClassifier do
  @moduledoc """
  Pure classifier for `gh pr view --json state,statusCheckRollup` payloads.

  Extracted from `SymphonyElixir.GitHubPr` to keep that file under the
  600-LOC cap (SYM-35 dedup-by-name logic pushed it over).
  """

  @type required_checks_status :: :all_green | :pending | {:red, [String.t()]}

  @doc """
  Pure classifier for the `{state, statusCheckRollup}` payload returned by
  `gh pr view --json state,statusCheckRollup`.

  Closed/merged PRs carry stale check rows from their last CI run. SODEV-824
  redispatch surfaced this: a prior closed fe-next-app PR left 2× qa-evidence
  FAILURE + review CANCELLED on the Linear attachment, poisoning the reduce
  in `default_required_checks_status/1` and parking the issue even though the
  new open backend PR was green. Same poison-pill class as SODEV-765 (PR #40
  filtered closed PRs in `ready?/1` but missed this path). Treat non-OPEN as
  `:all_green` so they don't vote in CI status aggregation.
  """
  @spec classify_pr_view_payload(map()) :: required_checks_status()
  def classify_pr_view_payload(%{"state" => state, "statusCheckRollup" => list})
      when is_list(list) and state != "OPEN",
      do: :all_green

  def classify_pr_view_payload(%{"statusCheckRollup" => list}) when is_list(list),
    do: classify_status_check_rollup(list)

  def classify_pr_view_payload(_), do: :all_green

  @doc """
  Pure classifier for a list of `statusCheckRollup` entries returned by
  `gh pr view --json statusCheckRollup`.

  Handles both shapes the GitHub GraphQL API can emit:

  * `CheckRun` — `%{"status" => "COMPLETED" | _, "conclusion" => "SUCCESS" | "FAILURE" | …, "name" => name}`
  * `StatusContext` — `%{"state" => "SUCCESS" | "FAILURE" | "PENDING" | _, "context" => name}`

  Treats SUCCESS / NEUTRAL / SKIPPED / STALE as green; FAILURE / CANCELLED /
  TIMED_OUT / ACTION_REQUIRED / ERROR as red; everything else as pending.

  GitHub returns one rollup entry per check-run *attempt*. Agents push more
  than once per ticket (first push → CI fails → fix → re-push → CI passes),
  so the rollup carries every prior FAILURE alongside the latest SUCCESS.
  GitHub's own UI dedupes by name and shows the latest; we do the same here
  via `dedupe_latest_by_name/1`. Without dedup, SODEV-824 PR #595 reduced
  to `{:red, ["qa-evidence"]}` despite the latest qa-evidence being green,
  parking the issue. See SYM-35.
  """
  @spec classify_status_check_rollup([map()]) :: required_checks_status()
  def classify_status_check_rollup(list) when is_list(list) do
    deduped = dedupe_latest_by_name(list)
    reds = deduped |> Enum.filter(&red_check?/1) |> Enum.map(&check_name/1)

    cond do
      reds != [] -> {:red, reds}
      Enum.any?(deduped, &pending_check?/1) -> :pending
      true -> :all_green
    end
  end

  defp dedupe_latest_by_name(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {entry, idx}, acc ->
      name = check_name(entry)

      case Map.get(acc, name) do
        nil ->
          Map.put(acc, name, {entry, idx})

        {existing, _existing_idx} ->
          if newer?(entry, existing) do
            Map.put(acc, name, {entry, idx})
          else
            acc
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(fn {_entry, idx} -> idx end)
    |> Enum.map(fn {entry, _idx} -> entry end)
  end

  defp newer?(new_entry, old_entry) do
    case {started_at(new_entry), started_at(old_entry)} do
      {"", ""} -> true
      {new, old} -> new >= old
    end
  end

  defp started_at(%{"startedAt" => s}) when is_binary(s), do: s
  defp started_at(_), do: ""

  @red_conclusions ~w(FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED)
  @red_states ~w(FAILURE ERROR)
  @pending_statuses ~w(IN_PROGRESS QUEUED PENDING WAITING REQUESTED)
  @pending_states ~w(PENDING EXPECTED)

  defp red_check?(%{"conclusion" => c}) when is_binary(c), do: c in @red_conclusions
  defp red_check?(%{"state" => s}) when is_binary(s), do: s in @red_states
  defp red_check?(_), do: false

  defp pending_check?(%{"status" => s}) when is_binary(s), do: s in @pending_statuses
  defp pending_check?(%{"state" => s}) when is_binary(s), do: s in @pending_states
  defp pending_check?(_), do: false

  defp check_name(%{"name" => n}) when is_binary(n), do: n
  defp check_name(%{"context" => n}) when is_binary(n), do: n
  defp check_name(_), do: "unknown"
end
