defmodule Mix.Tasks.Symphony.EvalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Eval

  test "--record writes a jsonl file at --output" do
    out = Path.join(System.tmp_dir!(), "mix_eval_record_#{:rand.uniform(1_000_000)}.jsonl")

    capture_io(fn ->
      Eval.run(["--record", "--output", out, "--dataset", "../evals/dataset"])
    end)

    assert File.exists?(out)
    File.rm!(out)
  end

  test "--diff exits 0 when comparing a recording against itself" do
    out = Path.join(System.tmp_dir!(), "mix_eval_diff_#{:rand.uniform(1_000_000)}.jsonl")
    Eval.run(["--record", "--output", out, "--dataset", "../evals/dataset"])

    output =
      capture_io(fn ->
        assert :ok = Eval.run(["--diff", "--baseline", out, "--candidate", out])
      end)

    assert output =~ "PASS"

    File.rm!(out)
  end
end
