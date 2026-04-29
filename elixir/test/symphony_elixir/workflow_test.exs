defmodule SymphonyElixir.WorkflowTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  describe "workflow_file_path/0" do
    setup do
      original_app_env = Application.get_env(:symphony_elixir, :workflow_file_path)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      original_os_env = System.get_env("SYMPHONY_WORKFLOW_FILE")
      System.delete_env("SYMPHONY_WORKFLOW_FILE")

      on_exit(fn ->
        if original_app_env do
          Application.put_env(:symphony_elixir, :workflow_file_path, original_app_env)
        else
          Application.delete_env(:symphony_elixir, :workflow_file_path)
        end

        if original_os_env do
          System.put_env("SYMPHONY_WORKFLOW_FILE", original_os_env)
        else
          System.delete_env("SYMPHONY_WORKFLOW_FILE")
        end
      end)

      :ok
    end

    test "defaults to cwd-relative WORKFLOW.md when no override is set" do
      expected = Path.join(File.cwd!(), "WORKFLOW.md")
      assert Workflow.workflow_file_path() == expected
    end

    test "Application env overrides default" do
      Application.put_env(:symphony_elixir, :workflow_file_path, "/tmp/app-env-workflow.md")
      assert Workflow.workflow_file_path() == "/tmp/app-env-workflow.md"
    end

    test "SYMPHONY_WORKFLOW_FILE env var overrides default when Application env unset" do
      System.put_env("SYMPHONY_WORKFLOW_FILE", "WORKFLOW.schools-out.md")
      expected = Path.join(File.cwd!(), "WORKFLOW.schools-out.md")
      assert Workflow.workflow_file_path() == expected
    end

    test "absolute SYMPHONY_WORKFLOW_FILE is honored as-is" do
      System.put_env("SYMPHONY_WORKFLOW_FILE", "/etc/symphony/WORKFLOW.tenant-x.md")
      assert Workflow.workflow_file_path() == "/etc/symphony/WORKFLOW.tenant-x.md"
    end

    test "Application env wins over SYMPHONY_WORKFLOW_FILE when both are set" do
      Application.put_env(:symphony_elixir, :workflow_file_path, "/tmp/app-env-wins.md")
      System.put_env("SYMPHONY_WORKFLOW_FILE", "/tmp/os-env-loses.md")
      assert Workflow.workflow_file_path() == "/tmp/app-env-wins.md"
    end
  end
end
