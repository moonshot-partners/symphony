defmodule SymphonyElixir.Orchestrator.CompletionSummary do
  @moduledoc """
  Posts the single human-facing completion/blocked comment for a run.

  Detailed internal artifacts are uploaded as one debug zip and linked from
  this comment instead of being scattered through the Linear thread.
  """

  require Logger

  alias SymphonyElixir.Orchestrator.DebugBundle
  alias SymphonyElixir.Tracker

  @max_ac_evidence_chars 3_000

  @spec publish_async(map(), String.t() | nil, map(), term(), String.t() | nil) :: :ok
  def publish_async(issue, target_state, running_entry, reason, parent_comment_id)
      when is_map(issue) and is_map(running_entry) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      publish(issue, target_state, running_entry, reason, parent_comment_id)
    end)

    :ok
  end

  @doc false
  @spec publish(map(), String.t() | nil, map(), term(), String.t() | nil) :: :ok
  def publish(issue, target_state, running_entry, reason, parent_comment_id) do
    bundle_result = DebugBundle.create_and_upload(issue, running_entry, reason)
    body = build_comment(issue, target_state, running_entry, reason, bundle_result)
    issue_id = Map.get(issue, :id)
    opts = if is_binary(parent_comment_id), do: [parent_id: parent_comment_id], else: []

    case Tracker.create_comment(issue_id, body, opts) do
      {:ok, comment_id} ->
        Logger.info("Completion summary posted issue=#{identifier(issue, running_entry)} comment=#{comment_id}")

      {:error, reason} ->
        Logger.warning("Completion summary failed issue=#{identifier(issue, running_entry)} reason=#{inspect(reason)}")
    end

    :ok
  end

  @doc false
  @spec build_comment(map(), String.t() | nil, map(), term(), {:ok, String.t()} | {:error, term()}) :: String.t()
  def build_comment(issue, target_state, running_entry, reason, bundle_result) do
    [
      heading(reason),
      "",
      "**Outcome:** #{outcome(reason, target_state)}",
      pr_line(issue),
      ac_evidence_block(running_entry),
      qa_line(reason),
      debug_bundle_line(bundle_result),
      "",
      "_Posted by Symphony. Detailed agent artifacts are in the debug bundle._"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp heading({:ci_red, _}), do: "## Blocked by CI"
  defp heading({:gate_d_substance_fail, _}), do: "## Blocked by AC evidence"
  defp heading({:conflict_disclosure_fail, _}), do: "## Blocked by scope disclosure"
  defp heading(:qa_artifact_missing), do: "## Blocked by missing visual QA evidence"
  defp heading(:qa_blocked), do: "## Blocked by QA self-review"
  defp heading(_), do: "## Ready for review"

  defp outcome({:ci_red, names}, target_state) do
    "Moved to `#{target_state}` because required checks are failing: #{inline_list(names)}."
  end

  defp outcome({:gate_d_substance_fail, failures}, target_state) do
    acs =
      failures
      |> Enum.map(fn %{ac_id: id, reason: reason} -> "AC #{id} (#{reason})" end)
      |> inline_list()

    "Moved to `#{target_state}` because verified AC claims lack resolvable evidence: #{acs}."
  end

  defp outcome({:conflict_disclosure_fail, files}, target_state) do
    "Moved to `#{target_state}` because the PR touched undisclosed files: #{inline_list(files)}."
  end

  defp outcome(:qa_artifact_missing, target_state) do
    "Moved to `#{target_state}` because the PR/ticket requires visual QA but no screenshot, video, or trace artifact was found."
  end

  defp outcome(:qa_blocked, target_state) do
    "Moved to `#{target_state}` because the PR self-review reported QA as blocked."
  end

  defp outcome(_reason, target_state), do: "Moved to `#{target_state}` after PR checks and Symphony gates passed."

  defp pr_line(%{repos: repos}) when is_list(repos) do
    urls =
      Enum.flat_map(repos, fn
        %{pr: %{url: url}} when is_binary(url) -> [url]
        _ -> []
      end)

    case urls do
      [] -> nil
      _ -> "**PR:** " <> Enum.join(urls, ", ")
    end
  end

  defp pr_line(_), do: nil

  defp ac_evidence_block(running_entry) do
    text =
      case Map.get(running_entry, :pinned_evidence_text) do
        %{} = sections -> Map.get(sections, "AC Evidence")
        _ -> nil
      end

    if is_binary(text) and String.trim(text) != "" do
      trimmed =
        text
        |> String.trim()
        |> String.slice(0, @max_ac_evidence_chars)

      suffix = if String.length(text) > @max_ac_evidence_chars, do: "\n\n_(truncated; full text in debug bundle)_", else: ""
      "### AC evidence\n\n#{trimmed}#{suffix}"
    else
      "**AC evidence:** not captured in the final agent text; see debug bundle for the last message."
    end
  end

  defp qa_line(:qa_artifact_missing), do: "**QA evidence:** missing; visual QA was required."

  defp qa_line(_reason) do
    "**QA evidence:** screenshots/video/trace are published separately when present; raw files are also in the debug bundle."
  end

  defp debug_bundle_line({:ok, url}), do: "**Debug bundle:** [agent-debug.zip](#{url})"
  defp debug_bundle_line({:error, reason}), do: "**Debug bundle:** unavailable (#{inspect(reason)})."

  defp inline_list(items) when is_list(items) do
    Enum.map_join(items, ", ", &"`#{&1}`")
  end

  defp inline_list(_), do: "`unknown`"

  defp identifier(issue, running_entry) do
    Map.get(issue, :identifier) || Map.get(running_entry, :identifier) || Map.get(issue, :id) || "unknown"
  end
end
