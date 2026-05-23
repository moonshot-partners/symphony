defmodule SymphonyElixir.Agent.AppServer.TransportGuardrailEnvTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.AppServer.Transport

  describe "guardrail_env/0" do
    test "returns [] when no guardrail is enabled in the agent runtime config" do
      settings = %{tdd_phase_enforcement: false}
      assert [] == Transport.guardrail_env(settings)
    end

    test "returns SYMPHONY_TDD_PHASE_ENFORCEMENT=enabled when the WORKFLOW config opts in" do
      settings = %{tdd_phase_enforcement: true}

      assert [{~c"SYMPHONY_TDD_PHASE_ENFORCEMENT", ~c"enabled"}] ==
               Transport.guardrail_env(settings)
    end

    test "tolerates a missing field gracefully (default OFF)" do
      assert [] == Transport.guardrail_env(%{})
    end
  end
end
