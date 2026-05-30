defmodule SymphonyElixir.Orchestrator.DebugBundleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.DebugBundle

  setup do
    Application.put_env(:symphony_elixir, :debug_bundle_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      qa_evidence_subpath: "fe-next-app/qa-evidence"
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :debug_bundle_test_recipient)
    end)

    :ok
  end

  test "creates a zip with agent internals and QA artifacts" do
    base = Path.join(System.tmp_dir!(), "debug-bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base, "state", "SODEV-343"]))
    File.mkdir_p!(Path.join([base, "fe-next-app", "qa-evidence"]))

    File.write!(Path.join([base, "state", "SODEV-343", "understanding.md"]), """
    ## Plan

    - `src/app/page.tsx`
    """)

    File.write!(Path.join([base, "fe-next-app", "qa-evidence", "dialog.png"]), "png-bytes")
    File.write!(Path.join([base, "fe-next-app", "qa-evidence", "session.webm"]), "webm-bytes")

    on_exit(fn -> File.rm_rf!(base) end)

    running_entry = %{
      identifier: "SODEV-343",
      workspace_path: base,
      session_id: "session-1",
      turn_count: 2,
      last_agent_text: "## AC Evidence\n\n- AC 1: verified — src/app/page.tsx:10",
      pinned_evidence_text: %{
        "AC Extracted" => "## AC Extracted\n\n1. Dialog appears",
        "AC Evidence" => "## AC Evidence\n\n- AC 1: verified — src/app/page.tsx:10"
      }
    }

    assert {:ok, zip_path} = DebugBundle.create(issue(), running_entry, :ready_for_review)
    on_exit(fn -> File.rm(zip_path) end)

    {:ok, files} = :zip.list_dir(String.to_charlist(zip_path))

    names =
      files
      |> Enum.flat_map(fn
        {:zip_file, name, _info, _comment, _offset, _comp_size} -> [to_string(name)]
        _ -> []
      end)
      |> MapSet.new()

    assert MapSet.member?(names, "metadata.json")
    assert MapSet.member?(names, "last-agent-message.md")
    assert MapSet.member?(names, "ac-extracted.md")
    assert MapSet.member?(names, "ac-evidence.md")
    assert MapSet.member?(names, "understanding.md")
    assert MapSet.member?(names, "qa-evidence/fe-next-app/qa-evidence/dialog.png")
    assert MapSet.member?(names, "qa-evidence/fe-next-app/qa-evidence/session.webm")

    {:ok, [{~c"ac-evidence.md", ac_evidence}]} =
      :zip.extract(String.to_charlist(zip_path), [:memory, {:file_list, [~c"ac-evidence.md"]}])

    assert ac_evidence =~ "AC 1: verified"
  end

  test "create handles sparse oversized QA artifacts by adding a skipped marker" do
    base = Path.join(System.tmp_dir!(), "debug-bundle-large-#{System.unique_integer([:positive])}")
    evidence_dir = Path.join([base, "fe-next-app", "qa-evidence"])
    File.mkdir_p!(evidence_dir)
    large_path = Path.join(evidence_dir, "huge.trace")

    {:ok, file} = :file.open(String.to_charlist(large_path), [:write])
    {:ok, _} = :file.position(file, 100_000_001)
    :ok = :file.write(file, "x")
    :ok = :file.close(file)

    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, zip_path} = DebugBundle.create(issue(), %{workspace_path: base}, :ready_for_review)
    on_exit(fn -> File.rm(zip_path) end)

    {:ok, files} = :zip.list_dir(String.to_charlist(zip_path))

    names =
      files
      |> Enum.flat_map(fn
        {:zip_file, name, _info, _comment, _offset, _comp_size} -> [to_string(name)]
        _ -> []
      end)
      |> MapSet.new()

    assert MapSet.member?(names, "qa-evidence/fe-next-app/qa-evidence/huge.trace.skipped.txt")
  end

  test "create handles unreadable QA artifact paths and missing PR metadata" do
    base = Path.join(System.tmp_dir!(), "debug-bundle-broken-#{System.unique_integer([:positive])}")
    evidence_dir = Path.join([base, "fe-next-app", "qa-evidence"])
    File.mkdir_p!(evidence_dir)
    broken_path = Path.join(evidence_dir, "broken.png")
    File.write!(broken_path, "png")
    File.chmod!(broken_path, 0)

    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, zip_path} =
             DebugBundle.create(
               issue(%{repos: [%{pr: nil}]}),
               %{workspace_path: base, last_agent_text: ""},
               :ready_for_review
             )

    on_exit(fn -> File.rm(zip_path) end)

    {:ok, files} = :zip.list_dir(String.to_charlist(zip_path))

    names =
      files
      |> Enum.flat_map(fn
        {:zip_file, name, _info, _comment, _offset, _comp_size} -> [to_string(name)]
        _ -> []
      end)
      |> MapSet.new()

    assert MapSet.member?(names, "last-agent-message.md")
    assert MapSet.member?(names, "qa-evidence/fe-next-app/qa-evidence/broken.png.skipped.txt")
  end

  test "create handles issues without repo metadata" do
    assert {:ok, zip_path} = DebugBundle.create(%{}, %{workspace_path: nil}, :ready_for_review)
    on_exit(fn -> File.rm(zip_path) end)

    {:ok, [{~c"metadata.json", metadata}]} =
      :zip.extract(String.to_charlist(zip_path), [:memory, {:file_list, [~c"metadata.json"]}])

    assert Jason.decode!(metadata)["pr_urls"] == []
  end

  test "create_and_upload returns upload result and removes the temporary zip" do
    Application.put_env(:symphony_elixir, :debug_bundle_upload_module, __MODULE__.FakeUpload)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :debug_bundle_upload_module) end)

    assert {:ok, "https://uploads.example/debug.zip"} =
             DebugBundle.create_and_upload(issue(), %{workspace_path: nil}, :ready_for_review)

    assert_receive {:debug_bundle_uploaded, path}, 1_000
    refute File.exists?(path)
  end

  test "create_and_upload returns upload errors" do
    Application.put_env(:symphony_elixir, :debug_bundle_upload_module, __MODULE__.FailingUpload)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :debug_bundle_upload_module) end)

    assert {:error, :boom} = DebugBundle.create_and_upload(issue(), %{workspace_path: nil}, :ready_for_review)
  end

  test "create_and_upload returns create errors" do
    issue = issue(%{identifier: String.duplicate("x", 300)})

    assert {:error, _reason} = DebugBundle.create_and_upload(issue, %{workspace_path: nil}, :ready_for_review)
  end

  defp issue(overrides \\ %{}) do
    %Issue{
      id: "issue-343",
      identifier: "SODEV-343",
      title: "Add confirmation dialog",
      url: "https://linear.app/schoolsout/issue/SODEV-343",
      repos: [%{name: "fe-next-app", pr: %{url: "https://github.com/org/repo/pull/629"}}]
    }
    |> Map.merge(overrides)
  end

  defmodule FakeUpload do
    @moduledoc false
    def upload(path) do
      send(Application.fetch_env!(:symphony_elixir, :debug_bundle_test_recipient), {:debug_bundle_uploaded, path})
      {:ok, "https://uploads.example/debug.zip"}
    end
  end

  defmodule FailingUpload do
    @moduledoc false
    def upload(_path), do: {:error, :boom}
  end
end
