defmodule SymphonyElixir.Orchestrator.WorkpadStore do
  @moduledoc """
  Disk persistence for `Orchestrator.State.workpads` — the map of
  `issue_id => workpad_comment_id` the orchestrator uses to edit (rather
  than recreate) the Linear workpad on each turn.

  Before this module the map lived only in GenServer memory, so any
  symphony restart while a ticket was still "In Development" lost the
  comment id and the next dispatch posted a duplicate workpad on Linear.
  Reads tolerate a missing or corrupt file by returning `%{}` — a fresh
  empty map matches the previous in-memory default, so the orchestrator
  still boots even if state on disk is wiped or hand-edited.
  """

  @spec load(Path.t()) :: %{String.t() => String.t()}
  def load(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      Map.new(decoded, fn {k, v} -> {to_string(k), v} end)
      |> Enum.filter(fn {k, v} -> is_binary(k) and is_binary(v) end)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  @spec save(Path.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  def save(path, workpads) when is_binary(path) and is_map(workpads) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(workpads)) do
      :ok
    else
      {:error, _} = err -> err
    end
  end
end
