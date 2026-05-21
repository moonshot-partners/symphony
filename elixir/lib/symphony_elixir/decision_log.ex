defmodule SymphonyElixir.DecisionLog do
  @moduledoc """
  Append-only JSONL ledger of orchestrator decisions — AI-first observability
  for the K=1 PR re-engagement loop (SYM-16) and every other branch in the
  reconcile pipeline.

  Each call to `emit/3` appends one line of the shape
  `%{ts: ISO8601, event: "namespace.action", payload: <map>}` to the configured
  path. The default path is `/opt/symphony/state/decisions.jsonl` — same disk
  location as `runs.jsonl`, so `tail -f`, `grep`, and `jq` all just work for
  Claude / humans alike.

  Writes are gated by the `SYMPHONY_DECISION_LOG` env var (default ON since
  this is debugging infra — set to "0" to silence). All write errors are
  swallowed: the ledger MUST NOT propagate into orchestrator state.

  Why this exists: prior to SYM-16 bake, the K=1 loop branches in
  `PrReengagement`, `WorkpadPrSync.run_side_effects`, and the reconcile
  `pr_ready` short-circuit emitted zero log lines on the happy path, leaving
  the running orchestrator opaque to runtime investigation.
  """

  require Logger

  @default_path "/opt/symphony/state/decisions.jsonl"

  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("SYMPHONY_DECISION_LOG", "1") != "0"

  @spec emit(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def emit(event, payload \\ %{}, opts \\ [])
      when is_binary(event) and is_map(payload) and is_list(opts) do
    if enabled?() do
      path = Keyword.get(opts, :path, configured_path())
      do_emit(event, payload, path)
    else
      :ok
    end
  end

  # Resolved at call time so the orchestrator/host test suite can override the
  # default with `Application.put_env(:symphony_elixir, :decision_log_path, ...)`
  # — same pattern as `:workpads_path`, `:status_path`, `:log_file`.
  defp configured_path do
    Application.get_env(:symphony_elixir, :decision_log_path, @default_path)
  end

  defp do_emit(event, payload, path) do
    envelope = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event,
      payload: payload
    }

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, json} <- encode_envelope(envelope),
           :ok <- File.write(path, json <> "\n", [:append]) do
        :ok
      else
        {:error, reason} ->
          Logger.debug("DecisionLog write failed event=#{event} reason=#{inspect(reason)}")
          :ok
      end
    rescue
      e ->
        Logger.debug("DecisionLog raised event=#{event} error=#{inspect(e)}")
        :ok
    end
  end

  # Happy path: encode the envelope directly. If the payload carries something
  # Jason cannot serialize (PIDs, refs, functions), retry with the payload
  # stringified via `inspect/1` — guarantees the event still lands instead of
  # crashing the caller.
  defp encode_envelope(envelope) do
    case Jason.encode(envelope) do
      {:ok, json} ->
        {:ok, json}

      {:error, _} ->
        fallback = %{envelope | payload: inspect(envelope.payload, limit: :infinity, printable_limit: :infinity)}
        Jason.encode(fallback)
    end
  end
end
