defmodule SymphonyElixir.Cockpit.EvidenceStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Cockpit.EvidenceStore

  setup do
    store = Path.join(System.tmp_dir!(), "ev-store-#{System.unique_integer([:positive])}")
    System.put_env("SYMPHONY_COCKPIT_EVIDENCE_DIR", store)

    on_exit(fn ->
      System.delete_env("SYMPHONY_COCKPIT_EVIDENCE_DIR")
      File.rm_rf!(store)
    end)

    {:ok, store: store}
  end

  defp src_with(files) do
    dir = Path.join(System.tmp_dir!(), "ev-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, content} -> File.write!(Path.join(dir, name), content) end)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "read returns an empty manifest when the issue has no bundle" do
    assert EvidenceStore.read("unknown") == %{"items" => [], "report" => nil}
  end

  test "read returns an empty manifest when index.json is corrupt", %{store: store} do
    dir = Path.join(store, "corrupt")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.json"), "{not json")

    assert EvidenceStore.read("corrupt") == %{"items" => [], "report" => nil}
  end

  test "file_path refuses path traversal and missing files" do
    EvidenceStore.publish("issue-trav", src_with([{"ok.png", "x"}]))

    assert EvidenceStore.file_path("issue-trav", "ok.png")
    assert EvidenceStore.file_path("issue-trav", "../ok.png") == nil
    assert EvidenceStore.file_path("issue-trav", "nested/ok.png") == nil
    assert EvidenceStore.file_path("issue-trav", "absent.png") == nil
  end

  test "sanitizes issue ids that contain path separators", %{store: store} do
    EvidenceStore.publish("a/b/../c", src_with([{"ok.png", "x"}]))

    # the bundle lands in a single flattened directory under the store root
    assert [dir] = File.ls!(store)
    refute String.contains?(dir, "/")
    assert "ok.png" in names(EvidenceStore.read("a/b/../c"))
  end

  defp names(manifest), do: Enum.map(manifest["items"], & &1["name"])
end
