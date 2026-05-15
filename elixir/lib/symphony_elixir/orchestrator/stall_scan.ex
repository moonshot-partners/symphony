defmodule SymphonyElixir.Orchestrator.StallScan do
  @moduledoc """
  Pure scan over the orchestrator's `running` map that returns the
  subset of running issues considered stalled — i.e. whose latest
  activity timestamp is older than the configured stall timeout.

  Extracted from `SymphonyElixir.Orchestrator` (CP15). The function
  takes the bare `running` map plus the clocks/config the orchestrator
  already has (`now :: DateTime.t()`, `timeout_ms :: integer`) and
  returns a list of summaries the caller can iterate over to apply its
  state-mutating side effects (`terminate_running_issue/3`,
  `schedule_issue_retry/4`).

  No GenServer state is mutated here and no I/O is performed — the
  module is fully unit-testable against any `running`-shaped map.
  """

  @doc """
  Returns the list of stalled-issue summaries for the given `running`
  map. Each summary carries `:issue_id`, `:identifier` (falls back to
  the issue_id when missing), `:session_id` (falls back to `"n/a"`),
  the matching `:running_entry`, and `:elapsed_ms` (the actual elapsed
  milliseconds since the last agent activity).

  Entries with no `:last_agent_timestamp` and no `:started_at`, and
  entries whose `elapsed_ms` is at or below `timeout_ms`, are
  filtered out.
  """
  @spec find_stalled(map(), DateTime.t(), integer()) :: [
          %{
            issue_id: String.t(),
            identifier: String.t(),
            session_id: String.t(),
            running_entry: map(),
            elapsed_ms: non_neg_integer()
          }
        ]
  def find_stalled(running, %DateTime{} = now, timeout_ms) when is_map(running) and is_integer(timeout_ms) do
    running
    |> Enum.flat_map(fn {issue_id, entry} -> stalled_summary(issue_id, entry, now, timeout_ms) end)
  end

  defp stalled_summary(issue_id, entry, now, timeout_ms) do
    case elapsed_ms(entry, now) do
      elapsed when is_integer(elapsed) and elapsed > timeout_ms ->
        [
          %{
            issue_id: issue_id,
            identifier: Map.get(entry, :identifier, issue_id),
            session_id: session_id(entry),
            running_entry: entry,
            elapsed_ms: elapsed
          }
        ]

      _ ->
        []
    end
  end

  defp elapsed_ms(entry, now) do
    case last_activity_timestamp(entry) do
      %DateTime{} = timestamp -> max(0, DateTime.diff(now, timestamp, :millisecond))
      _ -> nil
    end
  end

  defp last_activity_timestamp(entry) when is_map(entry) do
    Map.get(entry, :last_agent_timestamp) || Map.get(entry, :started_at)
  end

  defp last_activity_timestamp(_entry), do: nil

  defp session_id(%{session_id: session_id}) when is_binary(session_id), do: session_id
  defp session_id(_entry), do: "n/a"
end
