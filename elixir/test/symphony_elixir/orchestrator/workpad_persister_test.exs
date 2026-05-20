defmodule SymphonyElixir.Orchestrator.WorkpadPersisterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Orchestrator.{WorkpadPersister, WorkpadStore}

  setup do
    path = Path.join(System.tmp_dir!(), "workpads-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  # A synchronous call drains the mailbox: casts enqueued before it are
  # guaranteed processed by the time it returns (GenServer FIFO).
  defp drain(pid), do: :sys.get_state(pid)

  describe "save_async/3 via a running persister" do
    test "writes the workpad map to disk", %{path: path} do
      pid = start_supervised!({WorkpadPersister, name: nil})

      :ok = WorkpadPersister.save_async(path, %{"SODEV-1" => "comment-aaa"}, pid)
      drain(pid)

      assert WorkpadStore.load(path) == %{"SODEV-1" => "comment-aaa"}
    end

    test "processes casts in arrival order — the last map handed over is the one on disk",
         %{path: path} do
      pid = start_supervised!({WorkpadPersister, name: nil})

      :ok = WorkpadPersister.save_async(path, %{"SODEV-1" => "v1"}, pid)
      :ok = WorkpadPersister.save_async(path, %{"SODEV-1" => "v2"}, pid)
      :ok = WorkpadPersister.save_async(path, %{"SODEV-1" => "v3"}, pid)
      drain(pid)

      assert WorkpadStore.load(path) == %{"SODEV-1" => "v3"}
    end

    test "save_async returns :ok and does not block the caller", %{path: path} do
      pid = start_supervised!({WorkpadPersister, name: nil})

      assert :ok = WorkpadPersister.save_async(path, %{"SODEV-9" => "c"}, pid)
    end
  end

  describe "handle_cast/2 — :save" do
    test "persists the map and keeps state", %{path: path} do
      assert {:noreply, :ok} =
               WorkpadPersister.handle_cast({:save, path, %{"SODEV-2" => "comment-bbb"}}, :ok)

      assert WorkpadStore.load(path) == %{"SODEV-2" => "comment-bbb"}
    end

    test "logs a warning and does not crash when the path is unwritable" do
      unwritable = "/this/path/does/not/exist/and/cannot/be/made/workpads.json"

      log =
        capture_log(fn ->
          assert {:noreply, :ok} =
                   WorkpadPersister.handle_cast({:save, unwritable, %{"SODEV-3" => "x"}}, :ok)
        end)

      assert log =~ "WorkpadStore.save failed"
    end
  end
end
