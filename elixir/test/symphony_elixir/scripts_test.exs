defmodule SymphonyElixir.ScriptsTest do
  use ExUnit.Case, async: true
  import Bitwise

  @repo_root Path.expand("../../..", __DIR__)
  @provision Path.join([@repo_root, "scripts", "provision_vps.sh"])

  describe "scripts/provision_vps.sh" do
    test "exists with executable bit" do
      assert File.exists?(@provision), "expected #{@provision} to exist"
      %File.Stat{mode: mode} = File.stat!(@provision)
      assert (mode &&& 0o111) != 0, "expected #{@provision} to be executable"
    end

    test "parses with bash -n" do
      {output, status} = System.cmd("bash", ["-n", @provision], stderr_to_stdout: true)
      assert status == 0, "bash -n failed for #{@provision}:\n#{output}"
    end

    test "uses strict mode (set -euo pipefail)" do
      contents = File.read!(@provision)
      assert contents =~ ~r/^set -euo pipefail\b/m, "provision script must enable strict mode"
    end

    test "pins erlang and elixir versions exactly" do
      contents = File.read!(@provision)
      assert contents =~ "1.19.5-otp-28", "elixir version pin missing"
      assert contents =~ "28.5", "erlang version pin missing"
    end

    test "emits systemd unit with --i-understand-that-this-will-be-running-without-the-usual-guardrails flag" do
      contents = File.read!(@provision)
      assert contents =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
    end

    test "writes env example with required keys (no secrets baked in)" do
      contents = File.read!(@provision)

      for key <- ~w(LINEAR_API_KEY GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN SYMPHONY_WORKFLOW_FILE) do
        assert contents =~ key, "env example missing key: #{key}"
      end

      refute contents =~ ~r/CLAUDE_CODE_OAUTH_TOKEN=sk-/,
             "provision script must not bake real tokens"

      refute contents =~ ~r/LINEAR_API_KEY=lin_/,
             "provision script must not bake real Linear keys"
    end
  end
end
