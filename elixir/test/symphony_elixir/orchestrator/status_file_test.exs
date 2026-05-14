defmodule SymphonyElixir.Orchestrator.StatusFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.StatusFile

  @moduletag :tmp_dir

  test "save writes running ids and drain flag as JSON", %{tmp_dir: dir} do
    path = Path.join(dir, "status.json")

    :ok = StatusFile.save(path, %{running: ["SODEV-123", "SODEV-456"], drain: false})

    assert {:ok, raw} = File.read(path)
    assert {:ok, decoded} = Jason.decode(raw)
    assert decoded == %{"running" => ["SODEV-123", "SODEV-456"], "drain" => false}
  end

  test "save with drain=true persists drain flag", %{tmp_dir: dir} do
    path = Path.join(dir, "status.json")

    :ok = StatusFile.save(path, %{running: [], drain: true})

    {:ok, raw} = File.read(path)
    assert Jason.decode!(raw) == %{"running" => [], "drain" => true}
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
