defmodule SymphonyElixir.Evals.Fixture do
  @moduledoc """
  Frozen scenario fixture for the eval harness, grounded in real production
  data from Hetzner `decisions.jsonl` + `runs.jsonl`.

  Each fixture is an `.exs` file at `evals/dataset/<id>.exs` evaluating to a
  map with `:issue`, `:events`, `:run`, and `:expected` keys. The `:events`
  list uses the production decisions.jsonl event vocabulary (see
  `evals/README.md`). The `:run` map mirrors a single row from runs.jsonl
  (turns, outcome, tokens, retries, pr_url) so the Runner can reproduce both
  the orchestrator's classification (from events) and the agent session
  outcome (from the run row).
  """

  defstruct [:id, :issue, :events, :run, :expected]

  @type t :: %__MODULE__{
          id: String.t(),
          issue: map(),
          events: [tuple()],
          run: map(),
          expected: map()
        }

  @spec load(Path.t()) :: t()
  def load(path) when is_binary(path) do
    id = path |> Path.basename(".exs")
    {data, _bindings} = Code.eval_file(path)

    %__MODULE__{
      id: id,
      issue: Map.fetch!(data, :issue),
      events: Map.fetch!(data, :events),
      run: Map.fetch!(data, :run),
      expected: Map.fetch!(data, :expected)
    }
  end

  @spec load_all(Path.t()) :: [t()]
  def load_all(dir) when is_binary(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load/1)
  end
end
