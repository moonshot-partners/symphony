defmodule SymphonyElixir.Orchestrator.StatusFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.StatusFile

  @moduletag :tmp_dir

  test "save writes running ids and drain flag as JSON", %{tmp_dir: dir} do
    path = Path.join(dir, "status.json")

    :ok = StatusFile.save(path, %{running: ["SODEV-123", "SODEV-456"], drain: false})

    assert {:ok, raw} = File.read(path)
    assert {:ok, decoded} = Jason.decode(raw)
    assert decoded["running"] == ["SODEV-123", "SODEV-456"]
    assert decoded["drain"] == false
    assert decoded["completed"] == []
    assert decoded["pr_engagements"] == %{}
  end

  test "save with drain=true persists drain flag", %{tmp_dir: dir} do
    path = Path.join(dir, "status.json")

    :ok = StatusFile.save(path, %{running: [], drain: true})

    {:ok, raw} = File.read(path)
    decoded = Jason.decode!(raw)
    assert decoded["running"] == []
    assert decoded["drain"] == true
    assert decoded["completed"] == []
    assert decoded["pr_engagements"] == %{}
  end

  test "save and load_runtime_state round-trip completed ids and PR engagements", %{tmp_dir: dir} do
    path = Path.join(dir, "status.json")
    pr_url = "https://github.com/org/repo/pull/123"

    :ok =
      StatusFile.save(path, %{
        running: [],
        drain: false,
        completed: MapSet.new(["issue-1", "issue-2"]),
        pr_engagements: %{
          pr_url => %{count: 1, cap_hit_shas: MapSet.new(["sha-1", "sha-2"])}
        }
      })

    assert %{
             completed: completed,
             pr_engagements: %{^pr_url => %{count: 1, cap_hit_shas: shas}}
           } = StatusFile.load_runtime_state(path)

    assert completed == MapSet.new(["issue-1", "issue-2"])
    assert shas == MapSet.new(["sha-1", "sha-2"])
  end

  test "load_runtime_state returns empty defaults when the file is absent", %{tmp_dir: dir} do
    path = Path.join(dir, "missing-status.json")

    assert StatusFile.load_runtime_state(path) == %{
             completed: MapSet.new(),
             pr_engagements: %{}
           }
  end

  test "load_runtime_state returns empty defaults for legacy status files", %{tmp_dir: dir} do
    path = Path.join(dir, "legacy-status.json")
    File.write!(path, Jason.encode!(%{"running" => [], "drain" => false}))

    assert StatusFile.load_runtime_state(path) == %{
             completed: MapSet.new(),
             pr_engagements: %{}
           }
  end

  test "load_runtime_state defaults malformed engagement entries", %{tmp_dir: dir} do
    path = Path.join(dir, "malformed-status.json")

    File.write!(
      path,
      Jason.encode!(%{
        "completed" => [],
        "pr_engagements" => %{"https://github.com/org/repo/pull/1" => %{"count" => "bad"}}
      })
    )

    assert %{
             pr_engagements: %{
               "https://github.com/org/repo/pull/1" => %{count: 0, cap_hit_shas: shas}
             }
           } = StatusFile.load_runtime_state(path)

    assert shas == MapSet.new()
  end

  test "save creates parent directory when missing", %{tmp_dir: dir} do
    path = Path.join([dir, "nested", "deep", "status.json"])

    :ok = StatusFile.save(path, %{running: [], drain: false})

    assert File.exists?(path)
  end

  test "drain_flag_path? returns true when the flag file exists", %{tmp_dir: dir} do
    flag_path = Path.join(dir, "drain.flag")
    File.touch!(flag_path)

    assert StatusFile.drain_requested?(flag_path) == true
  end

  test "drain_flag_path? returns false when the flag file is absent", %{tmp_dir: dir} do
    flag_path = Path.join(dir, "no-such-flag")
    assert StatusFile.drain_requested?(flag_path) == false
  end
end
