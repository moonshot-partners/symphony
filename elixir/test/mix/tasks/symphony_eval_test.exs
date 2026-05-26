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

  test "--diff exits nonzero on regression and prints deltas" do
    baseline = Path.join(System.tmp_dir!(), "mix_eval_b_#{:rand.uniform(1_000_000)}.jsonl")
    candidate = Path.join(System.tmp_dir!(), "mix_eval_c_#{:rand.uniform(1_000_000)}.jsonl")

    capture_io(fn ->
      Eval.run(["--record", "--output", baseline, "--dataset", "../evals/dataset"])
    end)

    File.read!(baseline)
    |> String.replace("\"In Code Review\"", "\"On Hold\"")
    |> then(&File.write!(candidate, &1))

    {exit_status, captured_stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          Eval.run(["--diff", "--baseline", baseline, "--candidate", candidate])
          :no_exit
        catch
          :exit, {:shutdown, code} -> code
        end
      end)

    assert exit_status == 1
    assert captured_stderr =~ "FAIL"
    assert captured_stderr =~ "final_state"

    File.rm!(baseline)
    File.rm!(candidate)
  end

  test "raises when neither --record nor --diff is passed" do
    assert_raise Mix.Error, ~r/must pass --record or --diff/, fn -> Eval.run([]) end
  end

  test "raises when --record is missing --output" do
    assert_raise Mix.Error, ~r/--record requires --output/, fn -> Eval.run(["--record"]) end
  end

  test "raises when --diff is missing --baseline" do
    assert_raise Mix.Error, ~r/--diff requires --baseline/, fn -> Eval.run(["--diff"]) end
  end

  test "raises when --diff is missing --candidate" do
    assert_raise Mix.Error, ~r/--diff requires --candidate/, fn -> Eval.run(["--diff", "--baseline", "/tmp/x.jsonl"]) end
  end

  test "raises on an unrecognized option" do
    assert_raise Mix.Error, ~r/Invalid option/, fn -> Eval.run(["--unknown", "x"]) end
  end
end
