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

  describe "WORKFLOW.md prompt body" do
    test "every state in '## Status map' section is in tracker.active_states or terminal_states" do
      original_workflow_path = Workflow.workflow_file_path()
      on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
      Workflow.clear_workflow_file_path()

      {:ok, %{config: config, prompt: prompt}} = Workflow.load()

      tracker = Map.fetch!(config, "tracker")
      active = Map.get(tracker, "active_states", [])
      terminal = Map.get(tracker, "terminal_states", [])
      configured = MapSet.new(active ++ terminal)

      section = extract_status_map_section(prompt)
      assert section != "", "WORKFLOW.md prompt is missing a '## Status map' section"

      mentioned = extract_state_names_from_status_map(section)

      assert MapSet.size(mentioned) > 0,
             "Could not parse any state names from '## Status map' section"

      unknown = MapSet.difference(mentioned, configured)

      assert MapSet.size(unknown) == 0,
             "## Status map mentions states not in tracker.active_states/terminal_states: " <>
               inspect(MapSet.to_list(unknown))
    end
  end

  defp extract_status_map_section(prompt) do
    case Regex.run(~r/## Status map\n(.*?)(?=\n## |\z)/s, prompt) do
      [_full, body] -> body
      _ -> ""
    end
  end

  defp extract_state_names_from_status_map(section) do
    ~r/^-\s+`([^`]+)`/m
    |> Regex.scan(section)
    |> Enum.flat_map(fn [_full, captured] -> split_state_list(captured) end)
    |> MapSet.new()
  end

  defp split_state_list(text) do
    text
    |> String.split(~r/`,\s*`/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
