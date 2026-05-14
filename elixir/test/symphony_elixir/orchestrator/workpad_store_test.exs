defmodule SymphonyElixir.Orchestrator.WorkpadStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.WorkpadStore

  setup do
    dir = Path.join(System.tmp_dir!(), "workpad-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "workpads.json")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: path, dir: dir}
  end

  test "load/1 returns empty map when file missing", %{path: path} do
    assert WorkpadStore.load(path) == %{}
  end

  test "save/2 then load/1 round-trips the workpads map", %{path: path} do
    workpads = %{"SODEV-435" => "comment-abc", "SODEV-765" => "comment-xyz"}
    assert WorkpadStore.save(path, workpads) == :ok
    assert WorkpadStore.load(path) == workpads
  end

  test "load/1 returns empty map when file is corrupt", %{path: path} do
    File.write!(path, "{not valid json")
    assert WorkpadStore.load(path) == %{}
  end

  test "save/2 creates the parent directory when missing", %{dir: dir} do
    nested_path = Path.join([dir, "nested", "deep", "workpads.json"])
    workpads = %{"SODEV-1" => "c1"}
    assert WorkpadStore.save(nested_path, workpads) == :ok
    assert WorkpadStore.load(nested_path) == workpads
  end

  test "save/2 overwrites an existing file", %{path: path} do
    :ok = WorkpadStore.save(path, %{"A" => "1"})
    :ok = WorkpadStore.save(path, %{"B" => "2"})
    assert WorkpadStore.load(path) == %{"B" => "2"}
  end

  test "load/1 ignores entries with non-string values", %{path: path} do
    File.write!(path, ~s({"GOOD":"comment-1","BAD":42,"ALSO_GOOD":"comment-2"}))
    assert WorkpadStore.load(path) == %{"GOOD" => "comment-1", "ALSO_GOOD" => "comment-2"}
  end
end
