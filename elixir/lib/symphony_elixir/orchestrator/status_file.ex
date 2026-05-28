defmodule SymphonyElixir.Orchestrator.StatusFile do
  @moduledoc """
  Externally-readable snapshot of orchestrator runtime state — used by the
  deploy script to know whether it is safe to restart symphony.

  Two surfaces:

  * `save/2` — writes `%{running: [issue_id, ...], drain: bool}` plus small
    resumable orchestration state as JSON to disk. Mirrors the `WorkpadStore`
    pattern: parent dirs auto-created, payload is tiny, every poll tick
    overwrites.
  * `drain_requested?/1` — checks for a sentinel flag file. Touched by the
    deploy script before the restart; orchestrator reads on every tick and
    flips `state.drain` so new agents stop being dispatched while in-flight
    ones run to completion.

  Two files instead of one because the inbound signal (operator wants drain)
  is operator-side, the outbound snapshot (running count) is symphony-side —
  giving each direction its own file keeps the protocol stateless on both
  ends.
  """

  @spec save(Path.t(), %{
          required(:running) => [String.t()],
          required(:drain) => boolean(),
          optional(atom()) => term()
        }) :: :ok
  def save(path, %{running: running, drain: drain} = status)
      when is_binary(path) and is_list(running) and is_boolean(drain) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(status_payload(status)))
    :ok
  end

  @spec drain_requested?(Path.t()) :: boolean()
  def drain_requested?(path) when is_binary(path), do: File.exists?(path)

  @spec load_runtime_state(Path.t()) :: %{completed: term(), pr_engagements: map()}
  def load_runtime_state(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      %{
        completed: load_completed(decoded),
        pr_engagements: load_pr_engagements(decoded)
      }
    else
      _ -> %{completed: MapSet.new(), pr_engagements: %{}}
    end
  end

  defp status_payload(%{running: running, drain: drain} = status) do
    %{
      "running" => running,
      "drain" => drain,
      "completed" => encode_completed(Map.get(status, :completed, MapSet.new())),
      "pr_engagements" => encode_pr_engagements(Map.get(status, :pr_engagements, %{}))
    }
  end

  defp encode_completed(%MapSet{} = completed), do: MapSet.to_list(completed)

  defp encode_pr_engagements(engagements) when is_map(engagements) do
    Map.new(engagements, fn {pr_url, engagement} ->
      {pr_url, encode_pr_engagement(engagement)}
    end)
  end

  defp encode_pr_engagement(%{count: count, cap_hit_shas: shas}) do
    %{
      "count" => count,
      "cap_hit_shas" => encode_completed(shas)
    }
  end

  defp load_completed(%{"completed" => completed}) when is_list(completed) do
    completed
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp load_completed(_), do: MapSet.new()

  defp load_pr_engagements(%{"pr_engagements" => engagements}) when is_map(engagements) do
    Map.new(engagements, fn {pr_url, engagement} ->
      {pr_url, load_pr_engagement(engagement)}
    end)
  end

  defp load_pr_engagements(_), do: %{}

  defp load_pr_engagement(%{"count" => count, "cap_hit_shas" => shas}) when is_integer(count) and is_list(shas) do
    %{
      count: count,
      cap_hit_shas:
        shas
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()
    }
  end

  defp load_pr_engagement(_), do: %{count: 0, cap_hit_shas: MapSet.new()}
end
