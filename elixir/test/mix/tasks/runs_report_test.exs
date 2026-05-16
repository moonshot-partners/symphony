defmodule Mix.Tasks.Runs.ReportTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Runs.Report

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("runs.report")
    :ok
  end

  test "renders empty report when input is missing" do
    in_temp_repo(fn ->
      output =
        capture_io(fn ->
          Report.run(["--input", "no-such-file.jsonl", "--output", "OUT.md"])
        end)

      assert output =~ "Wrote OUT.md (0 runs from no-such-file.jsonl)"
      assert File.read!("OUT.md") =~ "No runs recorded yet"
    end)
  end

  test "renders report from a runs.jsonl with valid lines" do
    in_temp_repo(fn ->
      content = """
      {"ticket":"T-1","outcome":"merged","tokens":10,"recorded_at":"2026-05-16T01:00:00Z"}
      {"ticket":"T-2","outcome":"no_pr","tokens":5,"recorded_at":"2026-05-16T02:00:00Z"}
      """

      File.write!("runs.jsonl", content)

      output =
        capture_io(fn ->
          Report.run(["--input", "runs.jsonl", "--output", "OUT.md"])
        end)

      assert output =~ "Wrote OUT.md (2 runs from runs.jsonl)"
      body = File.read!("OUT.md")
      assert body =~ "Total runs: 2"
      assert body =~ "merged: 1"
      assert body =~ "no_pr: 1"
    end)
  end

  test "uses default --input and --output when omitted" do
    in_temp_repo(fn ->
      output = capture_io(fn -> Report.run([]) end)

      assert output =~ "Wrote SYMPHONY_RUNS.md"
      assert File.exists?("SYMPHONY_RUNS.md")
    end)
  end

  test "raises Mix.Error on invalid option" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Report.run(["--bogus", "x"])
    end
  end

  test "raises Mix.Error when input file cannot be read (not enoent)" do
    in_temp_repo(fn ->
      File.mkdir!("a-dir.jsonl")

      assert_raise Mix.Error, ~r/Cannot read a-dir\.jsonl/, fn ->
        Report.run(["--input", "a-dir.jsonl", "--output", "OUT.md"])
      end
    end)
  end

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "runs-report-task-test-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end
end
