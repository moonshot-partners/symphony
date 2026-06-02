defmodule SymphonyElixir.OperationalViewTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.OperationalView

  setup do
    evidence_root = Path.join(System.tmp_dir!(), "operational-view-evidence-#{System.unique_integer([:positive])}")
    summary_root = Path.join(System.tmp_dir!(), "operational-view-summary-#{System.unique_integer([:positive])}")

    previous_evidence_root = System.get_env("SYMPHONY_COCKPIT_EVIDENCE_DIR")
    previous_summary_root = System.get_env("SYMPHONY_COCKPIT_SUMMARY_DIR")

    System.put_env("SYMPHONY_COCKPIT_EVIDENCE_DIR", evidence_root)
    System.put_env("SYMPHONY_COCKPIT_SUMMARY_DIR", summary_root)

    on_exit(fn ->
      restore_env_var("SYMPHONY_COCKPIT_EVIDENCE_DIR", previous_evidence_root)
      restore_env_var("SYMPHONY_COCKPIT_SUMMARY_DIR", previous_summary_root)
      File.rm_rf!(evidence_root)
      File.rm_rf!(summary_root)
    end)

    :ok
  end

  test "stores and deletes run summaries through the operational boundary" do
    assert :ok = OperationalView.put_run_summary("issue-1", "## Ready\n")
    assert OperationalView.read_run_summary("issue-1") == "## Ready\n"

    assert :ok = OperationalView.delete_run_summary("issue-1")
    assert OperationalView.read_run_summary("issue-1") == nil
  end

  test "publishes and deletes evidence through the operational boundary" do
    source = Path.join(System.tmp_dir!(), "operational-view-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "01-proof.png"), "image")
    File.write!(Path.join(source, "qa-report.md"), "verified")

    on_exit(fn -> File.rm_rf!(source) end)

    assert :ok = OperationalView.publish_evidence("issue-2", source)

    manifest = OperationalView.read_evidence("issue-2")
    assert manifest["report"] == "verified"
    assert [%{"kind" => "image", "name" => "01-proof.png"}] = manifest["items"]

    assert :ok = OperationalView.delete_evidence("issue-2")
    assert OperationalView.read_evidence("issue-2") == %{"items" => [], "report" => nil}
  end

  defp restore_env_var(key, nil), do: System.delete_env(key)
  defp restore_env_var(key, value), do: System.put_env(key, value)
end
