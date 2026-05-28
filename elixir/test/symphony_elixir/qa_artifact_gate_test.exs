defmodule SymphonyElixir.QaArtifactGateTest do
  @moduledoc """
  Unit coverage for `SymphonyElixir.QaArtifactGate`.

  SYM-34 closes the gap surfaced on SODEV-892 (2026-05-23): the agent's PR
  body claimed `- Result: PASS` but no qa-evidence artifacts (screenshot,
  webm, zip) ever materialized on disk. The fe-next-app CI gate only
  checks for the textual `## QA self-review` section; this Symphony-side
  gate refutes a PASS claim that has no supporting artifact file.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.QaArtifactGate

  setup do
    base = Path.join(System.tmp_dir!(), "symphony-qa-gate-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, tmp: base}
  end

  describe "validate/3 — body without PASS claim" do
    test "returns :ok when body is nil" do
      assert QaArtifactGate.validate(nil, "/nonexistent", "issue-1") == :ok
    end

    test "returns :ok when body has no Result line" do
      body = "## Summary\n\nFixed the thing.\n"
      assert QaArtifactGate.validate(body, "/nonexistent", "issue-1") == :ok
    end

    test "returns :ok when body has Result: BLOCKED (handled elsewhere)" do
      body = "## QA self-review\n\n- Result: BLOCKED — staging auth failed\n"
      assert QaArtifactGate.validate(body, "/nonexistent", "issue-1") == :ok
    end

    test "returns :ok when body has Result: FAIL (handled elsewhere)" do
      body = "## QA self-review\n\n- Result: FAIL\n"
      assert QaArtifactGate.validate(body, "/nonexistent", "issue-1") == :ok
    end

    test "returns :ok for NOT REQUIRED when the ticket is not visual" do
      body = "## QA self-review\n\nNo browser QA needed.\n\n- Result: NOT REQUIRED\n"

      assert QaArtifactGate.validate(body, "/nonexistent", "issue-1", issue_description: "Update a TypeScript helper return value.") == :ok
    end

    test "requires artifacts for NOT REQUIRED when the ticket has visual AC", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = "## QA self-review\n\nNo browser QA needed.\n\n- Result: NOT REQUIRED\n"

      assert QaArtifactGate.validate(body, ws, "issue-visual", issue_description: "The availability badge shows Last Spots on the activity page.") == {:fail, :no_artifact}
    end

    test "requires artifacts when the PR body describes visual behavior even without PASS", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)

      body = """
      ## Summary

      The public activity page now shows the Last Spots badge.

      ## QA self-review

      - Result: NOT REQUIRED
      """

      assert QaArtifactGate.validate(body, ws, "issue-body-visual") == {:fail, :no_artifact}
    end

    test "visual NOT REQUIRED passes when an artifact exists", %{tmp: tmp} do
      ws = setup_workspace(tmp, "fe-next-app/qa-evidence", "last-spots.png", "fakepngbytes")
      body = "## QA self-review\n\n- Result: NOT REQUIRED\n"

      assert QaArtifactGate.validate(body, ws, "issue-visual-ok", issue_description: "The availability badge shows Last Spots on the activity page.") == :ok
    end
  end

  describe "validate/3 — body claims PASS, workspace evidence" do
    test "returns :ok when workspace qa-evidence dir has a .png", %{tmp: tmp} do
      ws = setup_workspace(tmp, "fe-next-app/qa-evidence", "shot.png", "fakepngbytes")
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-2") == :ok
    end

    test "returns :ok with .webm artifact", %{tmp: tmp} do
      ws = setup_workspace(tmp, "fe-next-app/qa-evidence", "session.webm", "fakewebm")
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-3") == :ok
    end

    test "returns :ok with .zip artifact", %{tmp: tmp} do
      ws = setup_workspace(tmp, "fe-next-app/qa-evidence", "trace.zip", "fakezip")
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-4") == :ok
    end

    test "returns {:fail, :no_artifact} when qa-evidence dir is empty", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(Path.join(ws, "fe-next-app/qa-evidence"))
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-5") == {:fail, :no_artifact}
    end

    test "returns {:fail, :no_artifact} when qa-evidence dir does not exist", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-6") == {:fail, :no_artifact}
    end

    test "returns :ok for root-level Markdown-only PRs without runtime artifacts", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()

      assert QaArtifactGate.validate(body, ws, "issue-doc", changed_files: ["SYMPHONY_GREEN_CANARY.md"]) ==
               :ok
    end

    test "returns :ok for root-level .markdown files without runtime artifacts", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()

      assert QaArtifactGate.validate(body, ws, "issue-markdown", changed_files: ["README.markdown"]) == :ok
    end

    test "still requires artifacts for root-level non-Markdown changes", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()

      assert QaArtifactGate.validate(body, ws, "issue-json", changed_files: ["package.json"]) ==
               {:fail, :no_artifact}
    end

    test "still requires artifacts for nested Markdown changes", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()

      assert QaArtifactGate.validate(body, ws, "issue-docs", changed_files: ["docs/feature.md"]) ==
               {:fail, :no_artifact}
    end

    test "still requires artifacts when changed_files is malformed", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()

      assert QaArtifactGate.validate(body, ws, "issue-bad-files", changed_files: :unknown) ==
               {:fail, :no_artifact}
    end

    test "still requires artifacts when changed_files contains non-string paths", %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)
      body = pass_body()

      assert QaArtifactGate.validate(body, ws, "issue-non-string-file", changed_files: [nil]) ==
               {:fail, :no_artifact}
    end

    test "returns {:fail, :no_artifact} when artifact file is zero bytes", %{tmp: tmp} do
      ws = setup_workspace(tmp, "fe-next-app/qa-evidence", "shot.png", "")
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-7") == {:fail, :no_artifact}
    end

    test "ignores non-artifact files (qa-report.md alone is not enough)", %{tmp: tmp} do
      ws = setup_workspace(tmp, "fe-next-app/qa-evidence", "qa-report.md", "table only")
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, "issue-8") == {:fail, :no_artifact}
    end
  end

  describe "validate/3 — staged dir fallback" do
    test "returns :ok when /tmp staged dir has an artifact (workspace wiped)", %{tmp: tmp} do
      issue_id = "staged-issue-#{System.unique_integer([:positive])}"
      staged = Path.join(System.tmp_dir!(), "symphony-qa-staged-#{issue_id}")
      File.mkdir_p!(staged)
      File.write!(Path.join(staged, "shot.png"), "fakepng")
      on_exit(fn -> File.rm_rf(staged) end)

      ws = Path.join(tmp, "ws-wiped")
      File.mkdir_p!(ws)
      body = pass_body()
      assert QaArtifactGate.validate(body, ws, issue_id) == :ok
    end

    test "returns :ok when staged dir has artifact and workspace is nil", %{tmp: _tmp} do
      issue_id = "staged-only-#{System.unique_integer([:positive])}"
      staged = Path.join(System.tmp_dir!(), "symphony-qa-staged-#{issue_id}")
      File.mkdir_p!(staged)
      File.write!(Path.join(staged, "session.webm"), "fakewebm")
      on_exit(fn -> File.rm_rf(staged) end)

      body = pass_body()
      assert QaArtifactGate.validate(body, nil, issue_id) == :ok
    end
  end

  describe "validate/3 — missing inputs" do
    test "returns {:fail, :no_artifact} when both workspace and staged absent" do
      body = pass_body()
      issue_id = "absent-#{System.unique_integer([:positive])}"
      assert QaArtifactGate.validate(body, nil, issue_id) == {:fail, :no_artifact}
    end

    test "returns :ok when issue_id is nil (cannot check staged) but body has no PASS claim" do
      body = "## Summary\n\nNothing.\n"
      assert QaArtifactGate.validate(body, nil, nil) == :ok
    end

    test "returns {:fail, :no_artifact} when issue_id nil and body claims PASS" do
      body = pass_body()
      assert QaArtifactGate.validate(body, nil, nil) == {:fail, :no_artifact}
    end
  end

  describe "claims_pass?/1" do
    test "true when body has - Result: PASS line" do
      assert QaArtifactGate.claims_pass?("## QA self-review\n\n- Result: PASS\n") == true
    end

    test "true with surrounding whitespace" do
      assert QaArtifactGate.claims_pass?("- Result:   PASS  \n") == true
    end

    test "false for nil" do
      assert QaArtifactGate.claims_pass?(nil) == false
    end

    test "false when Result line is BLOCKED" do
      assert QaArtifactGate.claims_pass?("- Result: BLOCKED\n") == false
    end

    test "false when Result line is FAIL" do
      assert QaArtifactGate.claims_pass?("- Result: FAIL\n") == false
    end

    test "false when no Result line at all" do
      assert QaArtifactGate.claims_pass?("## Summary\n\nNo QA section.\n") == false
    end
  end

  describe "qa_artifact_required?/2" do
    test "true for PASS claims" do
      assert QaArtifactGate.qa_artifact_required?(pass_body()) == true
    end

    test "true for visual issue descriptions without PASS" do
      assert QaArtifactGate.qa_artifact_required?("- Result: NOT REQUIRED", "Badge is visible on the page") ==
               true
    end

    test "false for non-visual NOT REQUIRED" do
      assert QaArtifactGate.qa_artifact_required?("- Result: NOT REQUIRED", "Rename an internal helper") ==
               false
    end
  end

  defp pass_body do
    """
    ## QA self-review

    | # | Check | Result |
    |---|-------|--------|
    | AC#1 | thing works | PASS |

    - Result: PASS
    """
  end

  defp setup_workspace(tmp, subpath, filename, content) do
    ws = Path.join(tmp, "ws")
    full = Path.join(ws, subpath)
    File.mkdir_p!(full)
    File.write!(Path.join(full, filename), content)
    ws
  end
end
