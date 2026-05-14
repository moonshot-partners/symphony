defmodule SymphonyElixir.Orchestrator.StatusFile do
  @moduledoc """
  Externally-readable snapshot of orchestrator runtime state — used by the
  deploy script to know whether it is safe to restart symphony.

  Two surfaces:

  * `save/2` — writes `%{running: [issue_id, ...], drain: bool}` as JSON to
    disk. Mirrors the `WorkpadStore` pattern: parent dirs auto-created, payload
    is tiny, every poll tick overwrites.
  * `drain_requested?/1` — checks for a sentinel flag file. Touched by the
    deploy script before the restart; orchestrator reads on every tick and
    flips `state.drain` so new agents stop being dispatched while in-flight
    ones run to completion.

  Two files instead of one because the inbound signal (operator wants drain)
  is operator-side, the outbound snapshot (running count) is symphony-side —
  giving each direction its own file keeps the protocol stateless on both
  ends.
  """

  @spec save(Path.t(), %{required(:running) => [String.t()], required(:drain) => boolean()}) :: :ok
  def save(path, %{running: running, drain: drain}) when is_binary(path) and is_list(running) and is_boolean(drain) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"running" => running, "drain" => drain}))
    :ok
  end

  @spec drain_requested?(Path.t()) :: boolean()
  def drain_requested?(path) when is_binary(path), do: File.exists?(path)
end
