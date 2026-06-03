defmodule SymphonyElixir.Orchestrator.RuntimeStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.{RuntimeStore, StatusFile, WorkpadStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "runtime-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, status_path: Path.join(dir, "status.json"), workpads_path: Path.join(dir, "workpads.json"), drain_flag_path: Path.join(dir, "drain.flag")}
  end

  test "load combines resumable status and workpads into one persisted state", %{
    status_path: status_path,
    workpads_path: workpads_path
  } do
    pr_url = "https://github.com/org/repo/pull/44"

    :ok =
      StatusFile.save(status_path, %{
        running: [],
        drain: false,
        completed: MapSet.new(["issue-1"]),
        pr_engagements: %{
          pr_url => %{count: 2, cap_hit_shas: MapSet.new(["sha-1"])}
        }
      })

    :ok = WorkpadStore.save(workpads_path, %{"issue-1" => "comment-1"})

    assert %{
             workpads: %{"issue-1" => "comment-1"},
             completed: completed,
             pr_engagements: %{^pr_url => %{count: 2, cap_hit_shas: shas}}
           } = RuntimeStore.load(status_path, workpads_path)

    assert completed == MapSet.new(["issue-1"])
    assert shas == MapSet.new(["sha-1"])
  end

  test "load returns empty defaults when runtime files are absent", %{
    status_path: status_path,
    workpads_path: workpads_path
  } do
    assert RuntimeStore.load(status_path, workpads_path) == %{
             workpads: %{},
             completed: MapSet.new(),
             pr_engagements: %{}
           }
  end

  test "save_status preserves the deploy-visible status file shape", %{status_path: status_path} do
    assert :ok =
             RuntimeStore.save_status(status_path, %{
               running: ["issue-1"],
               drain: true,
               completed: MapSet.new(["done-1"]),
               pr_engagements: %{}
             })

    decoded = status_path |> File.read!() |> Jason.decode!()
    assert decoded["running"] == ["issue-1"]
    assert decoded["drain"] == true
    assert decoded["completed"] == ["done-1"]
    assert decoded["pr_engagements"] == %{}
  end

  test "drain_requested? delegates the deploy drain flag check", %{drain_flag_path: drain_flag_path} do
    refute RuntimeStore.drain_requested?(drain_flag_path)
    File.touch!(drain_flag_path)
    assert RuntimeStore.drain_requested?(drain_flag_path)
  end
end
