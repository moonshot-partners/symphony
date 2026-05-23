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

    test "emits SYMPHONY_BASH_POLICY_ALLOW newline-joined when bash_policy_allow is populated" do
      settings = %{
        tdd_phase_enforcement: false,
        bash_policy_allow: ["rm -rf node_modules", "rm -rf \\.next"]
      }

      assert [
               {~c"SYMPHONY_BASH_POLICY_ALLOW", joined}
             ] = Transport.guardrail_env(settings)

      assert to_string(joined) == "rm -rf node_modules\nrm -rf \\.next"
    end

    test "omits SYMPHONY_BASH_POLICY_ALLOW when bash_policy_allow is empty" do
      settings = %{tdd_phase_enforcement: false, bash_policy_allow: []}
      assert [] == Transport.guardrail_env(settings)
    end

    test "stacks TDD + bash policy envs when both opt in" do
      settings = %{
        tdd_phase_enforcement: true,
        bash_policy_allow: ["git reset --hard origin/dev"]
      }

      env = Transport.guardrail_env(settings)
      assert Enum.any?(env, fn {k, _} -> k == ~c"SYMPHONY_TDD_PHASE_ENFORCEMENT" end)
      assert Enum.any?(env, fn {k, _} -> k == ~c"SYMPHONY_BASH_POLICY_ALLOW" end)
    end
  end
end
