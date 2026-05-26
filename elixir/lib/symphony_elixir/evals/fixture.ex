defmodule SymphonyElixir.Evals.Fixture do
  @moduledoc """
  Frozen scenario fixture for the eval harness.

  Each fixture is an `.exs` file at `evals/dataset/<id>.exs` evaluating to a
  map with `issue`, `events`, and `expected` keys. See `evals/README.md` for
  the schema.
  """

  defstruct [:id, :issue, :events, :expected]

  @type t :: %__MODULE__{
          id: String.t(),
          issue: map(),
          events: [tuple()],
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
