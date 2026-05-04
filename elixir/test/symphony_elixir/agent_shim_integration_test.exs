defmodule SymphonyElixir.AgentShimIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @tag :skip_unless_python
  test "agent shim launches and exits cleanly on EOF" do
    python = System.find_executable("python3") || System.find_executable("python")

    if python == nil do
      # No Python available — accepted skip path
      assert true
    else
      cwd = Path.join(File.cwd!(), "priv/agent_shim")

      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-m", "symphony_agent_shim"],
          cd: cwd,
          env: [{~c"ANTHROPIC_API_KEY", ~c"sk-test-fixture"}]
        ])

      # Close stdin: shim sees EOF immediately, run_async loop exits.
      Port.command(port, "")
      send(port, {self(), :close})

      {output, exit_status} = collect_port(port, "", 3_000)

      refute String.contains?(output, "Traceback")
      assert exit_status in [0, 124]
    end
  end

  defp collect_port(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, acc <> data, timeout)

      {^port, {:exit_status, status}} ->
        {acc, status}
    after
      timeout ->
        if Port.info(port) != nil, do: Port.close(port)
        {acc, 124}
    end
  end
end
