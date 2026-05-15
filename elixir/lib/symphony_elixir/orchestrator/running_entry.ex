defmodule SymphonyElixir.Orchestrator.RunningEntry do
  @moduledoc """
  Pure helpers for inspecting and mutating per-issue running entries
  inside `SymphonyElixir.Orchestrator`'s `state.running` map, plus
  small utility lookups (`find_issue_by_id/2`, `find_id_for_ref/2`)
  and the orchestrator's standard log-context renderer.

  Extracted from `SymphonyElixir.Orchestrator` (CP16). Nothing here
  reaches into the GenServer process or performs I/O — every function
  takes its inputs explicitly and returns a value. `pop/2` does mutate
  the `State` struct, but only as a record update of the existing
  `running` map, which is what the orchestrator did inline anyway.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @doc "Find the `%Issue{}` whose `id` matches `issue_id`. Returns `nil` when absent."
  @spec find_issue_by_id([Issue.t() | any()], String.t()) :: Issue.t() | nil
  def find_issue_by_id(issues, issue_id) when is_list(issues) and is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} -> true
      _ -> false
    end)
  end

  @doc "Find the `issue_id` whose running entry monitors the given `ref`. Returns `nil` when none match."
  @spec find_id_for_ref(map(), reference()) :: String.t() | nil
  def find_id_for_ref(running, ref) when is_map(running) and is_reference(ref) do
    Enum.find_value(running, fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  @doc "Return the running entry's session_id when present and binary, otherwise the literal \"n/a\"."
  @spec session_id(any()) :: String.t()
  def session_id(%{session_id: session_id}) when is_binary(session_id), do: session_id
  def session_id(_entry), do: "n/a"

  @doc """
  Conditionally put `value` under `key` in the running `entry`.
  Skips when `value` is nil or `entry` is not a map.
  """
  @spec put_runtime_value(map(), atom(), term()) :: map()
  def put_runtime_value(entry, _key, nil), do: entry
  def put_runtime_value(entry, key, value) when is_map(entry), do: Map.put(entry, key, value)

  @doc """
  Store the workpad comment id on the running entry when it is a
  binary; pass-through when it is nil.
  """
  @spec put_workpad_comment_id(map(), String.t() | nil) :: map()
  def put_workpad_comment_id(entry, nil), do: entry

  def put_workpad_comment_id(entry, comment_id) when is_binary(comment_id),
    do: Map.put(entry, :workpad_comment_id, comment_id)

  @doc "Render the orchestrator's standard log context for an issue."
  @spec format_context(Issue.t()) :: String.t()
  def format_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @doc """
  Pop the running entry for `issue_id` from `state.running`, returning
  `{entry, new_state}`. Returns `{nil, state}` when the issue is not
  tracked.
  """
  @spec pop(State.t(), String.t()) :: {map() | nil, State.t()}
  def pop(%State{} = state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end
end
