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

  @empty %{"available" => false, "agents" => [], "retrying" => [], "polling" => nil}

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
    %{
      "id" => entry.identifier,
      "issueId" => entry.issue_id,
      "state" => entry.state,
      "turn" => entry.turn_count,
      "lastAction" => action(entry.last_agent_message),
      "lastEvent" => stringify(entry.last_agent_event),
      "runtimeSeconds" => entry.runtime_seconds,
      "startedAt" => iso8601(entry.started_at),
      "lastActivityAt" => iso8601(entry.last_agent_timestamp),
      "tokens" => %{
        "in" => entry.agent_input_tokens,
        "out" => entry.agent_output_tokens,
        "total" => entry.agent_total_tokens
      },
      "sessionId" => entry.session_id,
      "workerHost" => entry.worker_host
    }
  end

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

  # A human one-liner for the live "last action". `last_agent_message` is the
  # `summarize_update/1` map (`%{event, message, timestamp}`, atom keys) whose
  # `message` is the raw agent stream payload — a JSON-RPC map for tool/command
  # events, sometimes plain text. We surface the command being run or the
  # method, falling back to the event tag, and always return a string or nil so
  # the JSON-safe `lastAction` contract holds (a raw map here 502s the BFF).
  defp action(text) when is_binary(text), do: clip(text)

  defp action(%{} = summary) do
    message = Map.get(summary, :message) || Map.get(summary, "message")
    event = Map.get(summary, :event) || Map.get(summary, "event")
    from_message(message) || stringify(event)
  end

  defp action(_), do: nil

  defp from_message(%{"params" => %{"command" => cmd}}) when is_binary(cmd),
    do: "Running " <> clip(first_line(cmd))

  defp from_message(%{"method" => method}) when is_binary(method),
    do: method |> String.split("/") |> List.last()

  defp from_message(text) when is_binary(text) and text != "", do: clip(text)
  defp from_message(_), do: nil

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> List.first()

  defp clip(text) when is_binary(text) do
    if String.length(text) > 80, do: String.slice(text, 0, 79) <> "…", else: text
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(text) when is_binary(text), do: text
  defp iso8601(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(event), do: to_string(event)
end
