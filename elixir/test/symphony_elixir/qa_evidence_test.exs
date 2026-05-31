defmodule SymphonyElixir.QaEvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Cockpit.EvidenceStore
  alias SymphonyElixir.QaEvidence

  setup do
    store = Path.join(System.tmp_dir!(), "qa-store-#{System.unique_integer([:positive])}")
    System.put_env("SYMPHONY_COCKPIT_EVIDENCE_DIR", store)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    on_exit(fn ->
      System.delete_env("SYMPHONY_COCKPIT_EVIDENCE_DIR")
      File.rm_rf!(store)
    end)

    :ok
  end

  defp evidence_dir(files) do
    base = Path.join(System.tmp_dir!(), "qa-ev-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "fe-next-app/qa-evidence")
    File.mkdir_p!(dir)

    Enum.each(files, fn {name, content} ->
      File.write!(Path.join(dir, name), content)
    end)

    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  # maybe_publish runs publish in a supervised Task; poll the store until the
  # manifest lands (or time out).
  defp await_manifest(issue_id) do
    Enum.reduce_while(1..200, EvidenceStore.read(issue_id), fn _, _ ->
      manifest = EvidenceStore.read(issue_id)

      if manifest["items"] != [] or manifest["report"] != nil do
        {:halt, manifest}
      else
        Process.sleep(25)
        {:cont, manifest}
      end
    end)
  end

  defp names(manifest), do: Enum.map(manifest["items"], & &1["name"])

  describe "publish/3 — writes the bundle to the cockpit store" do
    test "stores screenshots + session video and the report inline; drops the trace zip" do
      base =
        evidence_dir([
          {"01-collapsed.png", "fake-png"},
          {"02-expanded.png", "fake-png"},
          {"qa-report.md", "- Result: PASS\n\n| Check | Result |\n| --- | --- |\n| toggle | PASS |\n"},
          {"session.webm", "fake-webm"},
          {"session.zip", "fake-trace"}
        ])

      dir = Path.join(base, "fe-next-app/qa-evidence")
      assert :ok == QaEvidence.publish("issue-42", dir)

      manifest = EvidenceStore.read("issue-42")
      assert names(manifest) == ["01-collapsed.png", "02-expanded.png", "session.webm"]

      kinds = Enum.map(manifest["items"], & &1["kind"])
      assert kinds == ["image", "image", "video"]

      assert manifest["report"] =~ "- Result: PASS"
      assert manifest["report"] =~ "| toggle | PASS |"

      # Files actually landed on disk and are servable; the trace zip is not.
      assert EvidenceStore.file_path("issue-42", "01-collapsed.png")
      assert EvidenceStore.file_path("issue-42", "session.webm")
      refute EvidenceStore.file_path("issue-42", "session.zip")
    end

    test "report is nil when no qa-report.md is present" do
      base = evidence_dir([{"shot.png", "png"}])
      dir = Path.join(base, "fe-next-app/qa-evidence")

      assert :ok == QaEvidence.publish("issue-noreport", dir)
      manifest = EvidenceStore.read("issue-noreport")
      assert names(manifest) == ["shot.png"]
      assert manifest["report"] == nil
    end

    test "republishing replaces the previous bundle" do
      first = evidence_dir([{"old.png", "old"}])
      assert :ok == QaEvidence.publish("issue-replace", Path.join(first, "fe-next-app/qa-evidence"))

      second = evidence_dir([{"new.png", "new"}])
      assert :ok == QaEvidence.publish("issue-replace", Path.join(second, "fe-next-app/qa-evidence"))

      assert names(EvidenceStore.read("issue-replace")) == ["new.png"]
      refute EvidenceStore.file_path("issue-replace", "old.png")
    end
  end

  describe "maybe_publish/2" do
    test "no-ops when workspace_path is nil" do
      assert :ok == QaEvidence.maybe_publish("issue-1", nil)
      assert EvidenceStore.read("issue-1") == %{"items" => [], "report" => nil}
    end

    test "no-ops when the qa-evidence directory is absent" do
      base = Path.join(System.tmp_dir!(), "qa-empty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)

      assert :ok == QaEvidence.maybe_publish("issue-1", base)
      assert EvidenceStore.read("issue-1") == %{"items" => [], "report" => nil}
    end

    test "publishes the live workspace bundle to the store asynchronously" do
      base =
        evidence_dir([
          {"01-collapsed.png", "fake-png"},
          {"qa-report.md", "- Result: PASS\n"},
          {"session.webm", "fake-webm"}
        ])

      assert :ok == QaEvidence.maybe_publish("issue-42", base)

      manifest = await_manifest("issue-42")
      assert "01-collapsed.png" in names(manifest)
      assert "session.webm" in names(manifest)
      assert manifest["report"] =~ "- Result: PASS"
    end

    test "still publishes after the workspace dir is removed before the async task runs" do
      base =
        evidence_dir([
          {"01-shot.png", "PNG-BYTES"},
          {"qa-report.md", "- Result: PASS\n"},
          {"session.webm", "WEBM-BYTES"}
        ])

      assert :ok == QaEvidence.maybe_publish("issue-race", base)
      File.rm_rf!(base)

      manifest = await_manifest("issue-race")
      assert "01-shot.png" in names(manifest)
      assert "session.webm" in names(manifest)
    end

    test "accepts (and ignores) a parent_id without touching the tracker" do
      base = evidence_dir([{"01-collapsed.png", "fake-png"}])

      assert :ok == QaEvidence.maybe_publish("issue-pp", base, parent_id: "workpad-comment-77")

      manifest = await_manifest("issue-pp")
      assert "01-collapsed.png" in names(manifest)
      refute_receive {:memory_tracker_comment, "issue-pp", _}, 200
    end
  end

  describe "stage_pending_publish/2 + maybe_publish/3 — SODEV-881" do
    test "stages evidence to a path that survives workspace removal, then publishes it" do
      base = evidence_dir([{"01.png", "PNG"}, {"qa-report.md", "- Result: PASS\n"}])

      assert :ok == QaEvidence.stage_pending_publish("issue-881", base)
      File.rm_rf!(base)

      # workspace gone, but maybe_publish must still pick up the staged copy
      assert :ok == QaEvidence.maybe_publish("issue-881", base)

      manifest = await_manifest("issue-881")
      assert "01.png" in names(manifest)
      assert manifest["report"] =~ "- Result: PASS"

      # staged dir cleaned up after publish (task `after` clause runs async)
      staged = Path.join(System.tmp_dir!(), "symphony-qa-staged-issue-881")

      eventually_gone? =
        Enum.reduce_while(1..40, false, fn _, _ ->
          if File.dir?(staged) do
            Process.sleep(25)
            {:cont, false}
          else
            {:halt, true}
          end
        end)

      assert eventually_gone?, "expected staged dir to be cleaned up after publish: #{staged}"
    end

    test "stage_pending_publish is a no-op when evidence dir absent" do
      base = Path.join(System.tmp_dir!(), "qa-empty-stage-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)

      assert :ok == QaEvidence.stage_pending_publish("issue-empty", base)
      refute File.dir?(Path.join(System.tmp_dir!(), "symphony-qa-staged-issue-empty"))
    end

    test "stage_pending_publish handles nil workspace_path silently" do
      assert :ok == QaEvidence.stage_pending_publish("issue-nil", nil)
    end

    test "maybe_publish prefers staged dir over workspace when both present" do
      staged_src = evidence_dir([{"staged.png", "STAGED"}])
      assert :ok == QaEvidence.stage_pending_publish("issue-prefer", staged_src)

      live_ws = evidence_dir([{"live.png", "LIVE"}])
      assert :ok == QaEvidence.maybe_publish("issue-prefer", live_ws)

      manifest = await_manifest("issue-prefer")
      assert "staged.png" in names(manifest)
      refute "live.png" in names(manifest)
    end
  end

  describe "Phase D — multi-path evidence collection" do
    defp multi_path_workspace(fe_files, be_files) do
      base = Path.join(System.tmp_dir!(), "qa-mp-#{System.unique_integer([:positive])}")
      fe_dir = Path.join(base, "fe-next-app/qa-evidence")
      be_dir = Path.join(base, "qa-evidence")
      File.mkdir_p!(fe_dir)
      File.mkdir_p!(be_dir)

      Enum.each(fe_files, fn {name, content} ->
        File.write!(Path.join(fe_dir, name), content)
      end)

      Enum.each(be_files, fn {name, content} ->
        File.write!(Path.join(be_dir, name), content)
      end)

      on_exit(fn -> File.rm_rf!(base) end)
      base
    end

    test "maybe_publish collects files from every configured subpath" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        qa_evidence_subpaths: ["fe-next-app/qa-evidence", "qa-evidence"]
      )

      base =
        multi_path_workspace(
          [
            {"fe-shot.png", "FE-PNG"},
            {"qa-report.md", "- Result: PASS\n"},
            {"session.webm", "FE-WEBM"}
          ],
          [{"be-rspec.txt", "rspec output here"}]
        )

      assert :ok == QaEvidence.maybe_publish("issue-mp-1", base)

      manifest = await_manifest("issue-mp-1")
      assert "fe-shot.png" in names(manifest)
      assert "session.webm" in names(manifest)
      assert manifest["report"] =~ "- Result: PASS"
    end

    test "stage_pending_publish snapshots every configured subpath before workspace wipe" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        qa_evidence_subpaths: ["fe-next-app/qa-evidence", "qa-evidence"]
      )

      base =
        multi_path_workspace(
          [{"fe-shot.png", "FE"}, {"qa-report.md", "- Result: PASS\n"}],
          [{"be-rspec.txt", "BE-output"}]
        )

      assert :ok == QaEvidence.stage_pending_publish("issue-mp-2", base)
      File.rm_rf!(base)

      assert :ok == QaEvidence.maybe_publish("issue-mp-2", base)

      manifest = await_manifest("issue-mp-2")
      assert "fe-shot.png" in names(manifest)
      assert manifest["report"] =~ "- Result: PASS"
    end
  end
end
