defmodule SymphonyElixir.Cockpit.RunSummaryStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Cockpit.RunSummaryStore

  setup do
    root = Path.join(System.tmp_dir!(), "summary-store-#{System.unique_integer([:positive])}")
    System.put_env("SYMPHONY_COCKPIT_SUMMARY_DIR", root)

    on_exit(fn ->
      System.delete_env("SYMPHONY_COCKPIT_SUMMARY_DIR")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "read returns nil when no summary is stored" do
    assert RunSummaryStore.read("unknown") == nil
  end

  test "put then read round-trips the markdown" do
    assert :ok == RunSummaryStore.put("issue-1", "## Ready for review\n")
    assert RunSummaryStore.read("issue-1") == "## Ready for review\n"
  end

  test "put overwrites the previous summary" do
    RunSummaryStore.put("issue-2", "old")
    RunSummaryStore.put("issue-2", "new")
    assert RunSummaryStore.read("issue-2") == "new"
  end

  test "sanitizes issue ids that contain path separators", %{root: root} do
    assert :ok == RunSummaryStore.put("a/b/../c", "x")
    assert RunSummaryStore.read("a/b/../c") == "x"

    # everything lands as flat files directly under the root, no nested dirs
    assert Enum.all?(File.ls!(root), &File.regular?(Path.join(root, &1)))
  end
end
