defmodule Mix.Tasks.Runs.WeeklyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Runs.Weekly

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("runs.weekly")
    :ok
  end

  test "renders empty report when input is missing" do
    in_temp_repo(fn ->
      output =
        capture_io(fn ->
          Weekly.run(["--input", "no-such-file.jsonl", "--output", "OUT.md"])
        end)

      assert output =~ "Wrote OUT.md (0 runs from no-such-file.jsonl)"
      assert File.read!("OUT.md") =~ "No runs in the last 7 days"
    end)
  end

  test "renders KPIs from a runs.jsonl with runs inside the 7-day window" do
    in_temp_repo(fn ->
      today = Date.utc_today() |> Date.to_iso8601()

      content = """
      {"ticket":"T-1","outcome":"pr_open","tokens_in":1000000,"tokens_out":1000000,"turns":2,"recorded_at":"#{today}T10:00:00Z"}
      """

      File.write!("runs.jsonl", content)

      output =
        capture_io(fn ->
          Weekly.run(["--input", "runs.jsonl", "--output", "OUT.md"])
        end)

      assert output =~ "Wrote OUT.md (1 runs from runs.jsonl)"
      body = File.read!("OUT.md")
      assert body =~ "# Symphony weekly report"
      assert body =~ "Runs: 1"
      assert body =~ "$18.00"
    end)
  end

  test "uses default --input and --output when omitted" do
    in_temp_repo(fn ->
      output = capture_io(fn -> Weekly.run([]) end)

      assert output =~ "Wrote SYMPHONY_WEEKLY.md"
      assert File.exists?("SYMPHONY_WEEKLY.md")
    end)
  end

  test "raises Mix.Error on invalid option" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Weekly.run(["--bogus", "x"])
    end
  end

  test "raises Mix.Error when input file cannot be read (not enoent)" do
    in_temp_repo(fn ->
      File.mkdir!("a-dir.jsonl")

      assert_raise Mix.Error, ~r/Cannot read a-dir\.jsonl/, fn ->
        Weekly.run(["--input", "a-dir.jsonl", "--output", "OUT.md"])
      end
    end)
  end

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "runs-weekly-task-test-#{unique}")

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
