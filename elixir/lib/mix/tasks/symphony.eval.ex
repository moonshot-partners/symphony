defmodule Mix.Tasks.Symphony.Eval do
  use Mix.Task

  @shortdoc "Record or diff Symphony eval harness runs"

  @moduledoc """
  Eval harness for the Symphony orchestrator.

  Usage:

      mix symphony.eval --record --output evals/results/baseline.jsonl
      mix symphony.eval --diff --baseline evals/results/baseline.jsonl \\
                              --candidate evals/results/candidate.jsonl

  Options:

      --record            Run all fixtures and write observations to --output
      --diff              Compare --baseline vs --candidate, exit nonzero on regression
      --output PATH       Output JSONL path (required with --record)
      --baseline PATH     Baseline JSONL path (required with --diff)
      --candidate PATH    Candidate JSONL path (required with --diff)
      --dataset DIR       Fixture directory (default: ../evals/dataset)
  """

  alias SymphonyElixir.Evals

  @switches [
    record: :boolean,
    diff: :boolean,
    output: :string,
    baseline: :string,
    candidate: :string,
    dataset: :string
  ]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:symphony_elixir)

    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

    cond do
      opts[:record] -> do_record(opts)
      opts[:diff] -> do_diff(opts)
      true -> Mix.raise("must pass --record or --diff")
    end
  end

  defp do_record(opts) do
    output = opts[:output] || Mix.raise("--record requires --output")
    dataset = opts[:dataset] || "../evals/dataset"

    :ok = Evals.record(output: output, dataset: dataset)
    Mix.shell().info("Wrote #{output}")
    :ok
  end

  defp do_diff(opts) do
    baseline = opts[:baseline] || Mix.raise("--diff requires --baseline")
    candidate = opts[:candidate] || Mix.raise("--diff requires --candidate")

    case Evals.diff(baseline, candidate) do
      {:ok, []} ->
        Mix.shell().info("PASS — all invariants intact across #{baseline} vs #{candidate}")
        :ok

      {:error, deltas} ->
        Mix.shell().error("FAIL — #{length(deltas)} invariant violation(s):")

        Enum.each(deltas, fn d ->
          Mix.shell().error("  [#{d.fixture_id}] #{d.field}: baseline=#{inspect(d.baseline)} candidate=#{inspect(d.candidate)}")
        end)

        exit({:shutdown, 1})
    end
  end
end
