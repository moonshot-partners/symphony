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

    test "emits SYMPHONY_BRANCH_NAMING_PATTERN when branch_naming_pattern is a non-empty string" do
      settings = %{branch_naming_pattern: "^(feat|fix)/SYM-[0-9]+(-[a-z0-9-]+)?$"}

      env = Transport.guardrail_env(settings)

      assert {~c"SYMPHONY_BRANCH_NAMING_PATTERN", charlist} =
               Enum.find(env, fn {k, _} -> k == ~c"SYMPHONY_BRANCH_NAMING_PATTERN" end)

      assert to_string(charlist) == "^(feat|fix)/SYM-[0-9]+(-[a-z0-9-]+)?$"
    end

    test "omits SYMPHONY_BRANCH_NAMING_PATTERN when branch_naming_pattern is nil or empty" do
      assert Enum.all?(
               Transport.guardrail_env(%{branch_naming_pattern: nil}),
               fn {k, _} -> k != ~c"SYMPHONY_BRANCH_NAMING_PATTERN" end
             )

      assert Enum.all?(
               Transport.guardrail_env(%{branch_naming_pattern: ""}),
               fn {k, _} -> k != ~c"SYMPHONY_BRANCH_NAMING_PATTERN" end
             )
    end

    test "stacks TDD + bash policy + branch_naming envs when all three opt in" do
      settings = %{
        tdd_phase_enforcement: true,
        bash_policy_allow: ["git reset --hard origin/dev"],
        branch_naming_pattern: "^agents/SODEV-[0-9]+"
      }

      env = Transport.guardrail_env(settings)
      assert Enum.any?(env, fn {k, _} -> k == ~c"SYMPHONY_TDD_PHASE_ENFORCEMENT" end)
      assert Enum.any?(env, fn {k, _} -> k == ~c"SYMPHONY_BASH_POLICY_ALLOW" end)
      assert Enum.any?(env, fn {k, _} -> k == ~c"SYMPHONY_BRANCH_NAMING_PATTERN" end)
    end

    test "emits MEMORIA_PROJECT_ID + MEMORIA_PROJECT_TAG when memoria has both fields" do
      settings = %{
        memoria: %{project_id: "574d7d43-82b9-44ac-b2c2-a8dc93e84c8e", project_tag: "schools-out"}
      }

      env = Transport.guardrail_env(settings)

      assert {~c"MEMORIA_PROJECT_ID", id_charlist} =
               Enum.find(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_ID" end)

      assert to_string(id_charlist) == "574d7d43-82b9-44ac-b2c2-a8dc93e84c8e"

      assert {~c"MEMORIA_PROJECT_TAG", tag_charlist} =
               Enum.find(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_TAG" end)

      assert to_string(tag_charlist) == "schools-out"
    end

    test "omits MEMORIA_PROJECT_ID/TAG when memoria is nil" do
      env = Transport.guardrail_env(%{memoria: nil})
      refute Enum.any?(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_ID" end)
      refute Enum.any?(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_TAG" end)
    end

    test "omits MEMORIA_PROJECT_ID/TAG when memoria is missing entirely" do
      env = Transport.guardrail_env(%{})
      refute Enum.any?(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_ID" end)
      refute Enum.any?(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_TAG" end)
    end

    test "omits MEMORIA_PROJECT_ID/TAG when either field is empty (all-or-nothing)" do
      empty_id = %{memoria: %{project_id: "", project_tag: "schools-out"}}
      empty_tag = %{memoria: %{project_id: "uuid", project_tag: ""}}
      nil_id = %{memoria: %{project_id: nil, project_tag: "schools-out"}}

      Enum.each([empty_id, empty_tag, nil_id], fn settings ->
        env = Transport.guardrail_env(settings)
        refute Enum.any?(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_ID" end)
        refute Enum.any?(env, fn {k, _} -> k == ~c"MEMORIA_PROJECT_TAG" end)
      end)
    end
  end
end
