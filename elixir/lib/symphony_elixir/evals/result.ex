defmodule SymphonyElixir.Evals.Result do
  @moduledoc """
  Captured observations from one fixture run. Serialized as one JSONL line
  per run into `evals/results/<run_id>.jsonl`.
  """

  defstruct [
    :fixture_id,
    :final_state,
    :gate_verdicts,
    :turn_count,
    :error_class,
    :pr_outcome,
    :decision_event_count,
    :duration_ms
  ]

  @type t :: %__MODULE__{
          fixture_id: String.t(),
          final_state: String.t(),
          gate_verdicts: [{String.t(), atom()}],
          turn_count: non_neg_integer(),
          error_class: atom() | nil,
          pr_outcome: String.t(),
          decision_event_count: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @spec to_jsonl(t()) :: String.t()
  def to_jsonl(%__MODULE__{} = r) do
    Jason.encode!(%{
      fixture_id: r.fixture_id,
      final_state: r.final_state,
      gate_verdicts: Enum.map(r.gate_verdicts, fn {gate, verdict} -> [gate, Atom.to_string(verdict)] end),
      turn_count: r.turn_count,
      error_class: r.error_class && Atom.to_string(r.error_class),
      pr_outcome: r.pr_outcome,
      decision_event_count: r.decision_event_count,
      duration_ms: r.duration_ms
    })
  end

  @spec from_jsonl(String.t()) :: {:ok, t()} | {:error, term()}
  def from_jsonl(line) when is_binary(line) do
    with {:ok, map} <- Jason.decode(line) do
      {:ok,
       %__MODULE__{
         fixture_id: map["fixture_id"],
         final_state: map["final_state"],
         gate_verdicts: Enum.map(map["gate_verdicts"], fn [g, v] -> {g, String.to_atom(v)} end),
         turn_count: map["turn_count"],
         error_class: map["error_class"] && String.to_atom(map["error_class"]),
         pr_outcome: map["pr_outcome"],
         decision_event_count: map["decision_event_count"],
         duration_ms: map["duration_ms"]
       }}
    end
  end

  @spec write_all([t()], Path.t()) :: :ok
  def write_all(results, path) when is_list(results) and is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    body =
      results
      |> Enum.map(&to_jsonl/1)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.write!(path, body)
  end

  @spec read_all(Path.t()) :: [t()]
  def read_all(path) when is_binary(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case from_jsonl(line) do
        {:ok, result} -> result
        {:error, reason} -> raise "Corrupt JSONL line in #{path}: #{inspect(reason)}"
      end
    end)
  end
end
