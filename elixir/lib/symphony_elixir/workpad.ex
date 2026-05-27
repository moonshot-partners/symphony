defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Synchronizes a Linear comment ("workpad") with running agent state.

  The orchestrator owns the workpad — the agent does not call Linear itself.
  Sync runs as a supervised fire-and-forget task; on success a
  `{:workpad_comment_created, issue_id, comment_id}` message is sent back to
  the requesting process so the comment id can be persisted on subsequent
  turns.
  """

  require Logger
  alias SymphonyElixir.GateDValidator
  alias SymphonyElixir.GitHubPr
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.Tracker

  @sync_events MapSet.new([
                 :session_started,
                 :turn_completed,
                 :turn_failed,
                 :turn_cancelled,
                 :turn_input_required,
                 :approval_required,
                 :turn_ended_with_error,
                 :pr_attached
               ])

  @max_agent_text_chars 4_000
  @heartbeat_threshold_seconds 15

  @doc """
  Updates the running entry's `last_agent_text` from the latest update and,
  when the event warrants it, fires a supervised workpad sync.
  Returns the updated running entry. When a create_comment is dispatched the
  returned entry carries `workpad_creating: true` so subsequent events arriving
  before `:workpad_comment_created` skip a second create. The orchestrator
  clears that flag (and stores the id) on the reply message.
  """
  @spec maybe_sync(map(), map(), pid()) :: map()
  def maybe_sync(running_entry, update, reply_to) when is_map(running_entry) and is_map(update) do
    running_entry = update_last_agent_text(running_entry, update)
    running_entry = update_last_error_reason(running_entry, update)

    cond do
      not enabled?() ->
        running_entry

      not is_binary(issue_id(running_entry)) ->
        running_entry

      should_sync?(update) ->
        sync_now(running_entry, reply_to)

      heartbeat_due?(running_entry) ->
        sync_now(running_entry, reply_to)

      true ->
        running_entry
    end
  end

  defp sync_now(running_entry, reply_to) do
    cond do
      is_binary(Map.get(running_entry, :workpad_comment_id)) ->
        schedule_update(running_entry, reply_to)
        Map.put(running_entry, :last_workpad_sync_at, DateTime.utc_now())

      Map.get(running_entry, :workpad_creating) == true ->
        running_entry

      true ->
        schedule_create(running_entry, reply_to)

        running_entry
        |> Map.put(:workpad_creating, true)
        |> Map.put(:last_workpad_sync_at, DateTime.utc_now())
    end
  end

  defp heartbeat_due?(running_entry) do
    case {Map.get(running_entry, :workpad_comment_id), Map.get(running_entry, :last_workpad_sync_at)} do
      {comment_id, %DateTime{} = last_sync_at} when is_binary(comment_id) ->
        DateTime.diff(DateTime.utc_now(), last_sync_at, :second) >= @heartbeat_threshold_seconds

      _ ->
        false
    end
  end

  defp enabled? do
    Application.get_env(:symphony_elixir, :workpad_enabled, true) == true
  end

  defp should_sync?(%{event: event}), do: MapSet.member?(@sync_events, event)
  defp should_sync?(_), do: false

  defp update_last_agent_text(running_entry, update) do
    case extract_agent_text(update) do
      nil -> running_entry
      text -> Map.put(running_entry, :last_agent_text, text)
    end
  end

  defp update_last_error_reason(running_entry, %{event: :turn_failed, details: details})
       when is_map(details) do
    case Map.get(details, "error") do
      error when is_binary(error) and error != "" ->
        Map.put(running_entry, :last_error_reason, error)

      _ ->
        running_entry
    end
  end

  defp update_last_error_reason(running_entry, _update), do: running_entry

  defp extract_agent_text(%{payload: payload}) when is_map(payload) do
    case payload do
      %{"method" => "item/agent_message", "params" => params} -> agent_message_text(params)
      _ -> nil
    end
  end

  defp extract_agent_text(_), do: nil

  defp agent_message_text(%{"text" => text}) when is_binary(text) and text != "", do: text

  defp agent_message_text(%{"item" => %{"text" => text}}) when is_binary(text) and text != "",
    do: text

  defp agent_message_text(%{"item" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> case do
      [] -> nil
      texts -> Enum.join(texts, "\n")
    end
  end

  defp agent_message_text(_), do: nil

  defp schedule_create(running_entry, reply_to) do
    issue_id = issue_id(running_entry)
    body = build_body(running_entry)

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      run_create(issue_id, body, reply_to)
    end)

    :ok
  end

  defp schedule_update(running_entry, reply_to) do
    issue_id = issue_id(running_entry)
    comment_id = Map.get(running_entry, :workpad_comment_id)
    body = build_body(running_entry)

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      run_update(issue_id, comment_id, body, reply_to)
    end)

    :ok
  end

  defp run_create(issue_id, body, reply_to) do
    case safely_call(fn -> Tracker.create_comment(issue_id, body) end) do
      {:ok, comment_id} when is_binary(comment_id) ->
        if is_pid(reply_to) do
          send(reply_to, {:workpad_comment_created, issue_id, comment_id})
        end

        :ok

      {:error, reason} ->
        Logger.warning("Workpad create failed issue_id=#{issue_id} reason=#{inspect(reason)}")

        if is_pid(reply_to) do
          send(reply_to, {:workpad_create_failed, issue_id, reason})
        end

        :ok
    end
  end

  defp run_update(issue_id, comment_id, body, reply_to) do
    case safely_call(fn -> Tracker.update_comment(comment_id, body) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Workpad update failed comment_id=#{comment_id} reason=#{inspect(reason)}")

        if is_pid(reply_to) do
          send(reply_to, {:workpad_update_failed, issue_id, comment_id, reason})
        end

        :ok
    end
  end

  defp safely_call(fun) do
    fun.()
  rescue
    error ->
      {:error, {:exception, Exception.message(error)}}
  catch
    kind, value ->
      {:error, {kind, value}}
  end

  defp issue_id(%{issue: %{id: id}}) when is_binary(id), do: id
  defp issue_id(%{issue: %{__struct__: _, id: id}}) when is_binary(id), do: id
  defp issue_id(_), do: nil

  defp build_body(running_entry) do
    issue = Map.get(running_entry, :issue) || %{}
    turn = Map.get(running_entry, :turn_count, 0)
    retry = Map.get(running_entry, :retry_attempt, 0)
    last_event = Map.get(running_entry, :last_agent_event)
    last_text = Map.get(running_entry, :last_agent_text)
    in_tok = Map.get(running_entry, :agent_input_tokens, 0)
    out_tok = Map.get(running_entry, :agent_output_tokens, 0)
    total_tok = Map.get(running_entry, :agent_total_tokens, 0)
    error_reason = Map.get(running_entry, :last_error_reason)
    evidence_text = pinned_evidence_text(running_entry)

    tokens = format_tokens(in_tok, out_tok, total_tok)
    pr_link = format_pr_link(issue)
    outcome = format_outcome(last_event, issue)
    phase = phase(last_event, issue)

    header =
      format_header(phase, last_event, %{
        turn: turn,
        retry: retry,
        tokens: tokens,
        pr_link: pr_link,
        outcome: outcome
      })

    sections =
      [
        header,
        format_live_activity(phase, last_event, turn),
        format_trust_summary(phase, issue, evidence_text),
        format_error_section(error_reason),
        format_primary_text(last_event, last_text)
      ]
      |> Enum.reject(fn s -> s == "" or s == nil end)

    Enum.join(sections, "\n\n") <> "\n"
  end

  defp phase(:pr_attached, issue) do
    case GitHubPr.required_checks_status(issue) do
      :pending -> :waiting_for_ci
      {:red, _names} -> :needs_attention
      _ -> :ready_for_review
    end
  end

  defp phase(nil, _issue), do: :starting
  defp phase(:session_started, _issue), do: :starting
  defp phase(:turn_completed, _issue), do: :working
  defp phase(:notification, _issue), do: :working
  defp phase(:turn_input_required, _issue), do: :needs_human_reply
  defp phase(:approval_required, _issue), do: :needs_approval
  defp phase(:turn_failed, _issue), do: :failed
  defp phase(:turn_ended_with_error, _issue), do: :failed
  defp phase(:turn_cancelled, _issue), do: :cancelled
  defp phase(_event, _issue), do: :working

  defp format_header(:waiting_for_ci, :pr_attached, %{tokens: tok, turn: t, retry: r, pr_link: link}) do
    parts = ["Status: Waiting for CI" <> link, tok, "#{t} turns"]
    parts = if r > 0, do: parts ++ ["#{r} retries"], else: parts
    Enum.join(parts, " · ")
  end

  defp format_header(:ready_for_review, :pr_attached, %{
         tokens: tok,
         turn: t,
         retry: r,
         pr_link: link,
         outcome: outcome
       }) do
    parts = ["Status: Ready for review" <> link, tok, "#{t} turns"]
    parts = if r > 0, do: parts ++ ["#{r} retries"], else: parts
    parts = if outcome != "", do: parts ++ [outcome], else: parts
    Enum.join(parts, " · ")
  end

  defp format_header(:needs_attention, :pr_attached, %{tokens: tok, turn: t, retry: r, pr_link: link}) do
    parts = ["Status: Needs attention" <> link, tok, "#{t} turns"]
    parts = if r > 0, do: parts ++ ["#{r} retries"], else: parts
    Enum.join(parts, " · ")
  end

  defp format_header(:starting, _event, _meta), do: "Status: Starting"

  defp format_header(phase, _event, meta) do
    "Status: #{status_label(phase)} · turn #{meta.turn} · #{meta.tokens}"
  end

  defp status_label(:working), do: "Working"
  defp status_label(:needs_human_reply), do: "Needs human reply"
  defp status_label(:needs_approval), do: "Needs approval"
  defp status_label(:failed), do: "Failed"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(phase) when is_atom(phase), do: phase |> Atom.to_string() |> String.replace("_", " ")

  defp format_live_activity(:starting, _event, _turn) do
    """
    Live activity

    Current step: Starting the agent.
    Last update: just now.
    Next: understand the request and plan the change.
    """
    |> String.trim()
  end

  defp format_live_activity(:working, _event, turn) do
    """
    Live activity

    Current step: Working on the requested change.
    Last update: just now.
    Progress: turn #{turn} is active.
    Next: verify the change and open a PR.
    """
    |> String.trim()
  end

  defp format_live_activity(:waiting_for_ci, _event, _turn) do
    """
    Live activity

    Current step: Waiting for GitHub checks.
    Last update: just now.
    What this means: the agent opened a PR and is waiting on external CI.
    Next: move to review when checks pass, or surface the failing check.
    """
    |> String.trim()
  end

  defp format_live_activity(:ready_for_review, _event, _turn) do
    """
    Live activity

    Current step: Ready for human review.
    Last update: just now.
    Next: review and approve the PR if it matches the request.
    """
    |> String.trim()
  end

  defp format_live_activity(:needs_attention, _event, _turn) do
    """
    Live activity

    Current step: Needs attention.
    Last update: just now.
    What this means: a required check or quality gate needs review.
    Next: inspect the PR checks before approving.
    """
    |> String.trim()
  end

  defp format_live_activity(:needs_human_reply, _event, _turn) do
    """
    Live activity

    Current step: Waiting for a human reply.
    Last update: just now.
    Next: answer the agent's question so work can continue.
    """
    |> String.trim()
  end

  defp format_live_activity(:needs_approval, _event, _turn) do
    """
    Live activity

    Current step: Waiting for approval.
    Last update: just now.
    Next: approve or reject the requested action.
    """
    |> String.trim()
  end

  defp format_live_activity(:failed, _event, _turn) do
    """
    Live activity

    Current step: Stopped with an error.
    Last update: just now.
    What this means: no code was merged by this run.
    Next: inspect the error below.
    """
    |> String.trim()
  end

  defp format_live_activity(:cancelled, _event, _turn) do
    """
    Live activity

    Current step: Cancelled.
    Last update: just now.
    What this means: no code was merged by this run.
    """
    |> String.trim()
  end

  defp format_trust_summary(:ready_for_review, issue, evidence_text) do
    [
      "Trust summary",
      "",
      "What changed: PR opened for human review.",
      "Scope control: Symphony checked the PR before moving this ticket to review.",
      "Acceptance criteria: #{evidence_summary(evidence_text)}",
      "Visual evidence: attached in the thread when the task produced screenshots or video.",
      "Pull request: #{plain_pr_link(issue)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_trust_summary(:waiting_for_ci, issue, evidence_text) do
    [
      "Trust summary",
      "",
      "What changed: PR opened and waiting for checks.",
      "Scope control: PR checks are still running.",
      "Acceptance criteria: #{evidence_summary(evidence_text)}",
      "Visual evidence: attached in the thread when the task produced screenshots or video.",
      "Pull request: #{plain_pr_link(issue)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_trust_summary(:needs_attention, issue, evidence_text) do
    [
      "Trust summary",
      "",
      "What changed: PR opened, but a check needs attention.",
      "Scope control: Symphony did not mark the work ready while checks are failing.",
      "Acceptance criteria: #{evidence_summary(evidence_text)}",
      "Visual evidence: attached in the thread when the task produced screenshots or video.",
      "Pull request: #{plain_pr_link(issue)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_trust_summary(_phase, _issue, _evidence_text), do: ""

  defp format_outcome(:pr_attached, issue) do
    if RunLedger.enabled?() do
      pr_url = pr_url_from_issue(issue)
      RunLedger.classify_outcome(%{pr_url: pr_url})
    else
      ""
    end
  end

  defp format_outcome(_event, _issue), do: ""

  defp pinned_evidence_text(%{pinned_evidence_text: %{} = evidence}) do
    Map.get(evidence, "AC Evidence")
  end

  defp pinned_evidence_text(_), do: nil

  defp evidence_summary(text) when is_binary(text) do
    count = evidence_count(text)

    cond do
      count > 0 -> "#{count} item#{plural(count)} documented in AC Evidence."
      String.trim(text) != "" -> "documented in AC Evidence."
      true -> "not posted yet."
    end
  end

  defp evidence_summary(_), do: "not posted yet."

  defp evidence_count(text) do
    case GateDValidator.parse_ac_evidence_section(text) do
      [] ->
        text
        |> String.split("\n")
        |> Enum.count(&String.match?(&1, ~r/^\s*(?:[-*]|\d+\.)\s+AC[\s#]*\d+\b/i))

      claims ->
        length(claims)
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp pr_url_from_issue(%{repos: repos}) when is_list(repos) do
    Enum.find_value(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp pr_url_from_issue(_), do: nil

  defp format_primary_text(:pr_attached, _last_text), do: ""
  defp format_primary_text(_event, last_text), do: format_last_text(last_text)

  defp format_tokens(0, 0, 0), do: "—"

  defp format_tokens(_in, _out, total) when is_integer(total) and total < 1000,
    do: "#{total} tok"

  defp format_tokens(_in, _out, total) when is_integer(total) do
    rounded = Float.round(total / 1000, 1)

    num =
      rounded
      |> :erlang.float_to_binary(decimals: 1)
      |> String.replace_suffix(".0", "")

    "#{num}k tok"
  end

  defp format_pr_link(%{repos: repos}) when is_list(repos) do
    Enum.find_value(repos, "", fn
      %{pr: %{url: url}, name: name} when is_binary(url) and is_binary(name) ->
        " · " <> render_pr_link(url, name)

      _ ->
        nil
    end) || ""
  end

  defp format_pr_link(_), do: ""

  defp plain_pr_link(issue) do
    case pr_url_from_issue(issue) do
      url when is_binary(url) -> url
      _ -> "not available yet"
    end
  end

  defp render_pr_link(url, repo_name) do
    short_repo =
      repo_name
      |> String.split("/")
      |> List.last()

    case String.split(url, "/pull/") do
      [_, rest] ->
        case String.replace(rest, ~r/\D.*/, "") do
          "" -> "[#{short_repo}](#{url})"
          pr_num -> "[##{pr_num} #{short_repo}](#{url})"
        end

      _ ->
        "[#{short_repo}](#{url})"
    end
  end

  defp format_error_section(nil), do: ""
  defp format_error_section(""), do: ""

  defp format_error_section(reason) when is_binary(reason) do
    "### Error\n\n> #{reason}"
  end

  defp format_last_text(nil), do: ""
  defp format_last_text(""), do: ""

  defp format_last_text(text) when is_binary(text) do
    text
    |> truncate()
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn line -> "> " <> line end)
  end

  defp truncate(text) when is_binary(text) do
    case String.length(text) do
      length when length <= @max_agent_text_chars -> text
      _ -> String.slice(text, 0, @max_agent_text_chars) <> "…"
    end
  end
end
