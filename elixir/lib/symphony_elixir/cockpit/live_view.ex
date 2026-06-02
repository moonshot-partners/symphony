defmodule SymphonyElixir.Cockpit.LiveView do
  @moduledoc """
  Serializes the orchestrator's in-memory runtime snapshot
  (`SymphonyElixir.Orchestrator.snapshot/0`) into the JSON-safe shape the
  cockpit `/live` route returns.

  This is the *live telemetry* regime of the cockpit. The board build carries
  slow structure (tickets, CI, PRs) and is cached for 60s; the run ledger
  carries finished-run outcomes; this carries what each agent is doing *right
  now* — current turn, last action, runtime, token counts — which changes every
  turn and must never be served from either of those stale-by-design surfaces.

  Pure by construction: `render/1` takes the snapshot map, or the `:timeout` /
  `:unavailable` atoms the snapshot wrapper returns when the orchestrator is
  busy or absent, and returns a fully materialized, `Jason`-encodable map.
  `DateTime`s become ISO8601 strings, the event tag becomes a string, and the
  agent pid and workspace path are dropped — never exposed to the browser.
  """

  alias SymphonyElixir.Orchestrator.AgentAction

  @empty %{"available" => false, "agents" => [], "retrying" => [], "polling" => nil}

  # Same Langfuse prefix the board uses (`Cockpit.BoardView`); the running
  # agent's trace id is already in the snapshot, so the live overlay can deep
  # link to the in-flight trace exactly like a finished card links to its run.
  @trace_base "https://cloud.langfuse.com/trace/"

  @doc """
  Render the runtime snapshot into the `/live` payload. Non-map inputs
  (`:timeout`, `:unavailable`) yield an empty payload flagged `available: false`
  so the browser can tell "no agents running" apart from "orchestrator
  unreachable".
  """
  @spec render(map() | :timeout | :unavailable) :: map()
  def render(snapshot) when is_map(snapshot) do
    %{
      "available" => true,
      "agents" => Enum.map(Map.get(snapshot, :running, []), &agent/1),
      "retrying" => Enum.map(Map.get(snapshot, :retrying, []), &retry/1),
      "polling" => polling(Map.get(snapshot, :polling))
    }
  end

  def render(_unavailable), do: @empty

  defp agent(entry) do
    last_action = AgentAction.line(entry.last_agent_message)
    last_event = stringify(entry.last_agent_event)

    %{
      "id" => entry.identifier,
      "issueId" => entry.issue_id,
      "state" => entry.state,
      "turn" => entry.turn_count,
      "phase" => phase(entry.last_agent_event, last_action),
      "lastAction" => last_action,
      "lastEvent" => last_event,
      "events" => Enum.map(entry.recent_events, &live_event/1),
      "runtimeSeconds" => entry.runtime_seconds,
      "startedAt" => iso8601(entry.started_at),
      "lastActivityAt" => iso8601(entry.last_agent_timestamp),
      "tokens" => %{
        "in" => entry.agent_input_tokens,
        "out" => entry.agent_output_tokens,
        "total" => entry.agent_total_tokens
      },
      "sessionId" => entry.session_id,
      "workerHost" => entry.worker_host,
      "costUsd" => entry.agent_cost_usd,
      "traceUrl" => trace_url(entry.langfuse_trace_id)
    }
  end

  defp trace_url(id) when is_binary(id) and id != "", do: @trace_base <> id
  defp trace_url(_), do: nil

  defp retry(entry) do
    %{
      "id" => Map.get(entry, :identifier) || entry.issue_id,
      "attempt" => entry.attempt,
      "dueInMs" => entry.due_in_ms,
      "error" => Map.get(entry, :error)
    }
  end

  defp polling(nil), do: nil

  defp polling(polling) do
    %{
      "checking" => Map.get(polling, :checking?, false),
      "nextPollInMs" => Map.get(polling, :next_poll_in_ms),
      "intervalMs" => Map.get(polling, :poll_interval_ms)
    }
  end

  defp phase(nil, _action), do: "starting"
  defp phase(:session_started, _action), do: "planning"
  defp phase(:turn_input_required, _action), do: "blocked"
  defp phase(:approval_required, _action), do: "blocked"
  defp phase(:turn_failed, _action), do: "failed"
  defp phase(:turn_ended_with_error, _action), do: "failed"
  defp phase(:turn_cancelled, _action), do: "cancelled"
  defp phase(:pr_attached, _action), do: "reviewing"
  defp phase(:turn_completed, _action), do: "reviewing"

  defp phase(_event, action) when is_binary(action) do
    cond do
      String.starts_with?(action, "Running") -> "verifying"
      String.starts_with?(action, "Editing") -> "building"
      true -> "building"
    end
  end

  defp phase(_event, _action), do: "building"

  # One timeline row: the event tag, its one-liner action, and when it
  # happened. The action string is `AgentAction.line/1` so the timeline and
  # the headline `lastAction` read the same way.
  defp live_event(%{event: event, action: action, at: at}) do
    %{"event" => stringify(event), "action" => action, "at" => iso8601(at)}
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(text) when is_binary(text), do: text
  defp iso8601(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(event), do: to_string(event)
end
