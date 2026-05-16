defmodule SymphonyElixir.QaEvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.QaEvidence

  defmodule FakeUpload do
    @moduledoc false
    def upload(path), do: {:ok, "https://uploads.example/#{Path.basename(path)}"}
  end

  defmodule FailingUpload do
    @moduledoc false
    def upload(_path), do: {:error, :boom}
  end

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :qa_evidence_upload_module, FakeUpload)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :qa_evidence_upload_module)
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

  describe "maybe_publish/2" do
    test "no-ops when workspace_path is nil" do
      assert :ok == QaEvidence.maybe_publish("issue-1", nil)
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "no-ops when the qa-evidence directory is absent" do
      base = Path.join(System.tmp_dir!(), "qa-empty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)

      assert :ok == QaEvidence.maybe_publish("issue-1", base)
      refute_receive {:memory_tracker_comment, _, _}, 200
    end

    test "uploads screenshots and posts a comment with the report table inline" do
      base =
        evidence_dir([
          {"01-collapsed.png", "fake-png"},
          {"02-expanded.png", "fake-png"},
          {"qa-report.md", "| Check | Result |\n| --- | --- |\n| toggle | PASS |\n"},
          {"session.webm", "fake-webm"},
          {"session.zip", "fake-trace"}
        ])

      assert :ok == QaEvidence.maybe_publish("issue-42", base)

      assert_receive {:memory_tracker_comment, "issue-42", body}, 2_000
      assert body =~ "## QA self-review evidence"
      assert body =~ "| toggle | PASS |"
      assert body =~ "![01-collapsed.png](https://uploads.example/01-collapsed.png)"
      assert body =~ "![02-expanded.png](https://uploads.example/02-expanded.png)"
      assert body =~ "[session.webm](https://uploads.example/session.webm)"
      assert body =~ "[session.zip](https://uploads.example/session.zip)"
      assert body =~ "trace.playwright.dev"
    end

    test "still posts a comment when every upload fails" do
      Application.put_env(:symphony_elixir, :qa_evidence_upload_module, FailingUpload)

      base = evidence_dir([{"01-collapsed.png", "fake-png"}])

      assert :ok == QaEvidence.maybe_publish("issue-7", base)

      assert_receive {:memory_tracker_comment, "issue-7", body}, 2_000
      assert body =~ "_(no screenshots uploaded)_"
    end

    test "threads parent_id to tracker.create_comment when provided" do
      base = evidence_dir([{"01-collapsed.png", "fake-png"}])

      assert :ok ==
               QaEvidence.maybe_publish("issue-pp", base, parent_id: "workpad-comment-77")

      assert_receive {:memory_tracker_comment, "issue-pp", _body}, 2_000
      assert_receive {:memory_tracker_comment_parent, "issue-pp", "workpad-comment-77"}, 1_000
    end

    test "omits parent linkage when no parent_id is provided" do
      base = evidence_dir([{"01-collapsed.png", "fake-png"}])

      assert :ok == QaEvidence.maybe_publish("issue-np", base)

      assert_receive {:memory_tracker_comment, "issue-np", _body}, 2_000
      refute_receive {:memory_tracker_comment_parent, "issue-np", _}, 200
    end
  end

  describe "build_comment/4" do
    test "renders report, screenshots, video and trace sections" do
      body =
        QaEvidence.build_comment(
          "| Check | Result |\n| --- | --- |\n| x | PASS |",
          [{"a.png", "https://u/a.png"}],
          "https://u/session.webm",
          "https://u/session.zip"
        )

      assert body =~ "## QA self-review evidence"
      assert body =~ "| x | PASS |"
      assert body =~ "### Screenshots"
      assert body =~ "![a.png](https://u/a.png)"
      assert body =~ "[session.webm](https://u/session.webm)"
      assert body =~ "[session.zip](https://u/session.zip)"
      assert body =~ "trace.playwright.dev"
    end

    test "handles missing report, video and trace" do
      body = QaEvidence.build_comment(nil, [], nil, nil)

      assert body =~ "## QA self-review evidence"
      assert body =~ "_(no screenshots uploaded)_"
      refute body =~ "session.webm"
      refute body =~ "session.zip"
    end

    test "defaults trace_url to nil (back-compat /3 arity)" do
      body = QaEvidence.build_comment(nil, [], "https://u/session.webm")

      assert body =~ "[session.webm](https://u/session.webm)"
      refute body =~ "session.zip"
    end
  end
end
