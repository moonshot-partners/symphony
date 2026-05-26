defmodule SymphonyElixir.Evals do
  @moduledoc """
  Top-level facade for the eval harness. Drives:

    * `record/1` — load fixtures from a directory, run each, write Results to JSONL
    * `diff/2`   — compare two JSONL recordings via `Diff.compare/2`
  """

  alias SymphonyElixir.Evals.{Fixture, Result, Runner, Diff}

  @spec record(keyword()) :: :ok
  def record(opts) do
    dataset = Keyword.get(opts, :dataset, "evals/dataset")
    output = Keyword.fetch!(opts, :output)

    fixtures = Fixture.load_all(dataset)
    results = Enum.map(fixtures, &Runner.run/1)
    Result.write_all(results, output)
    :ok
  end

  @spec diff(Path.t(), Path.t(), keyword()) :: {:ok, []} | {:error, [map()]}
  def diff(baseline_path, candidate_path, opts \\ []) do
    baseline = Result.read_all(baseline_path)
    candidate = Result.read_all(candidate_path)
    Diff.compare(baseline, candidate, opts)
  end
end
