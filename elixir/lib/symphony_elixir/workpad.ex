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
  alias SymphonyElixir.Tracker

  @sync_events MapSet.new([
                 :session_started,
                 :turn_completed,
                 :turn_failed,
                 :turn_cancelled,
                 :turn_input_required,
                 :approval_required,
                 :turn_ended_with_error
               ])

  @max_agent_text_chars 4_000

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

    cond do
      not (enabled?() and should_sync?(update)) ->
        running_entry

      not is_binary(issue_id(running_entry)) ->
        running_entry

      is_binary(Map.get(running_entry, :workpad_comment_id)) ->
        schedule_update(running_entry, reply_to)
        running_entry

      Map.get(running_entry, :workpad_creating) == true ->
        running_entry

      true ->
        schedule_create(running_entry, reply_to)
        Map.put(running_entry, :workpad_creating, true)
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

      {:ok, _} ->
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
    identifier = Map.get(running_entry, :identifier) || Map.get(issue, :identifier)
    state = Map.get(issue, :state) || "(unknown)"
    workspace = Map.get(running_entry, :workspace_path) || "(pending)"
    worker_host = Map.get(running_entry, :worker_host) || "local"
    turn = Map.get(running_entry, :turn_count, 0)
    retry = Map.get(running_entry, :retry_attempt, 0)
    last_event = Map.get(running_entry, :last_agent_event)
    last_text = Map.get(running_entry, :last_agent_text)
    in_tok = Map.get(running_entry, :agent_input_tokens, 0)
    out_tok = Map.get(running_entry, :agent_output_tokens, 0)
    total_tok = Map.get(running_entry, :agent_total_tokens, 0)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    ## Symphony Workpad

    - **Issue**: #{identifier}
    - **State**: #{state}
    - **Workspace**: `#{workspace}`
    - **Worker host**: #{worker_host}
    - **Attempt**: #{retry}
    - **Turn**: #{turn}
    - **Last event**: #{format_event(last_event)}
    - **Updated**: #{now}

    ### Latest agent message

    #{format_last_text(last_text)}

    ### Tokens

    `in=#{in_tok} out=#{out_tok} total=#{total_tok}`
    """
  end

  defp format_event(nil), do: "(none)"
  defp format_event(event) when is_atom(event), do: Atom.to_string(event)
  defp format_event(event), do: inspect(event)

  defp format_last_text(nil), do: "_(no agent text yet)_"
  defp format_last_text(""), do: "_(no agent text yet)_"

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
