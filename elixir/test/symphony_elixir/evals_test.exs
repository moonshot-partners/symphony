defmodule SymphonyElixir.EvalsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Evals

  test "record/1 writes one Result per fixture to the output path" do
    out = Path.join(System.tmp_dir!(), "evals_record_test_#{:rand.uniform(1_000_000)}.jsonl")

    :ok = Evals.record(output: out, dataset: "../evals/dataset")

    lines = out |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 10

    File.rm!(out)
  end

  test "diff/2 returns :ok when comparing a recording against itself" do
    out = Path.join(System.tmp_dir!(), "evals_diff_test_#{:rand.uniform(1_000_000)}.jsonl")
    :ok = Evals.record(output: out, dataset: "../evals/dataset")

    assert {:ok, []} = Evals.diff(out, out)

    File.rm!(out)
  end
end
