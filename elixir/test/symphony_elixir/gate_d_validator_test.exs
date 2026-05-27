defmodule SymphonyElixir.GateDValidatorTest do
  @moduledoc """
  Unit coverage for `SymphonyElixir.GateDValidator`.

  Sister of `GateDObserver` — observer only checks the header exists;
  this validator parses each AC entry and rejects `verified` claims
  that lack a resolvable artifact reference. SYM-28 (AC2 of SYM-1).
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.GateDValidator

  describe "parse_ac_evidence_section/1" do
    test "returns empty list for nil and empty" do
      assert GateDValidator.parse_ac_evidence_section(nil) == []
      assert GateDValidator.parse_ac_evidence_section("") == []
    end

    test "returns empty list when no ## AC Evidence header present" do
      assert GateDValidator.parse_ac_evidence_section("## Summary\n\nbody") == []
    end

    test "parses a single verified claim with a file reference" do
      text = """
      ## AC Evidence

      - AC 1: verified — see lib/foo.ex:42
      """

      assert [%{ac_id: "1", status: :verified, refs: refs}] =
               GateDValidator.parse_ac_evidence_section(text)

      assert "lib/foo.ex:42" in refs
    end

    test "parses multiple claims in order" do
      text = """
      ## AC Evidence

      - AC 1: verified — test/foo_test.exs covers it
      - AC 2: skipped — no test framework
      - AC 3: verified via https://github.com/o/r/actions/runs/123
      """

      assert [
               %{ac_id: "1", status: :verified},
               %{ac_id: "2", status: :skipped},
               %{ac_id: "3", status: :verified, refs: refs3}
             ] = GateDValidator.parse_ac_evidence_section(text)

      assert Enum.any?(refs3, &String.contains?(&1, "github.com"))
    end

    test "stops parsing at the next H2 header" do
      text = """
      ## AC Evidence

      - AC 1: verified — file.ex:1

      ## Next Section

      - AC 2: verified
      """

      assert [%{ac_id: "1"}] = GateDValidator.parse_ac_evidence_section(text)
    end

    test "recognizes the AC#N shorthand format" do
      text = """
      ## AC Evidence

      AC#1 -> test_foo passes
      AC#2 -> blocked: no DB
      """

      assert [%{ac_id: "1", status: :verified}, %{ac_id: "2", status: :blocked}] =
               GateDValidator.parse_ac_evidence_section(text)
    end

    test "classifies status keywords case-insensitively" do
      text = """
      ## AC Evidence

      - AC 1: VERIFIED — file.ex:1
      - AC 2: Passed — file.ex:2
      - AC 3: SKIPPED — n/a
      - AC 4: blocked — env missing
      """

      assert [
               %{status: :verified},
               %{status: :verified},
               %{status: :skipped},
               %{status: :blocked}
             ] = GateDValidator.parse_ac_evidence_section(text)
    end

    test "marks entries with no recognizable status as :malformed" do
      text = """
      ## AC Evidence

      - AC 1: something happened
      """

      assert [%{ac_id: "1", status: :malformed}] =
               GateDValidator.parse_ac_evidence_section(text)
    end

    test "returns empty list when the AC Evidence section is header-only (no entries)" do
      assert GateDValidator.parse_ac_evidence_section("## AC Evidence\n\n") == []
    end

    test "extracts URL refs, path:line refs, and bare file refs" do
      text = """
      ## AC Evidence

      - AC 1: verified — lib/a.ex:10, lib/b.ex, https://example.com/x
      """

      assert [%{ac_id: "1", status: :verified, refs: refs}] =
               GateDValidator.parse_ac_evidence_section(text)

      assert "lib/a.ex:10" in refs
      assert "lib/b.ex" in refs
      assert "https://example.com/x" in refs
    end
  end

  describe "validate/2 — pure decision boundary" do
    setup do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :gate_d_ref_resolver_fn) end)
      :ok
    end

    test "returns :ok when no AC Evidence section present (defers to observer)" do
      assert GateDValidator.validate(nil, %{}) == :ok
      assert GateDValidator.validate("", %{}) == :ok
      assert GateDValidator.validate("## Summary\n\nbody", %{}) == :ok
    end

    test "returns :ok when every verified claim has at least one resolvable ref" do
      Application.put_env(:symphony_elixir, :gate_d_ref_resolver_fn, fn _ref, _ctx -> :ok end)

      text = """
      ## AC Evidence

      - AC 1: verified — lib/foo.ex:10
      - AC 2: verified — https://github.com/o/r/actions/runs/123
      """

      assert GateDValidator.validate(text, %{workspace_path: "/tmp/ws"}) == :ok
    end

    test "rejects a verified claim with no artifact reference" do
      text = """
      ## AC Evidence

      - AC 1: verified
      """

      assert {:fail, [%{ac_id: "1", reason: :unbacked}]} =
               GateDValidator.validate(text, %{})
    end

    test "rejects a verified claim where every ref fails to resolve" do
      Application.put_env(:symphony_elixir, :gate_d_ref_resolver_fn, fn _ref, _ctx ->
        {:error, :missing}
      end)

      text = """
      ## AC Evidence

      - AC 1: verified — lib/missing.ex:10, lib/also_missing.ex
      """

      assert {:fail, [%{ac_id: "1", reason: :no_resolvable_ref}]} =
               GateDValidator.validate(text, %{workspace_path: "/tmp/ws"})
    end

    test "passes when at least one ref resolves (any-of, not all-of)" do
      Application.put_env(:symphony_elixir, :gate_d_ref_resolver_fn, fn
        "lib/exists.ex" <> _, _ctx -> :ok
        _ref, _ctx -> {:error, :missing}
      end)

      text = """
      ## AC Evidence

      - AC 1: verified — lib/missing.ex, lib/exists.ex:42
      """

      assert GateDValidator.validate(text, %{workspace_path: "/tmp/ws"}) == :ok
    end

    test "resolves bare filename evidence inside a nested repo checkout" do
      workspace_path =
        Path.join(System.tmp_dir!(), "gate-d-nested-repo-#{System.unique_integer([:positive])}")

      file_path = Path.join([workspace_path, "fe-next-app", "SYMPHONY_WORKPAD_UX_CANARY.md"])

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "symphony workpad ux canary\n")

      on_exit(fn -> File.rm_rf(workspace_path) end)

      text = """
      ## AC Evidence

      - AC 4 — Canary test exits 0: `test "$(cat SYMPHONY_WORKPAD_UX_CANARY.md)" = "symphony workpad ux canary"` → **PASS**
      """

      assert GateDValidator.validate(text, %{workspace_path: workspace_path}) == :ok
    end

    test "skipped and blocked claims do not require artifacts" do
      Application.put_env(:symphony_elixir, :gate_d_ref_resolver_fn, fn _, _ ->
        raise "should not be called"
      end)

      text = """
      ## AC Evidence

      - AC 1: skipped — feature flagged off
      - AC 2: blocked — depends on infra
      """

      assert GateDValidator.validate(text, %{}) == :ok
    end

    test "malformed claim is flagged but does not block when no verification intent" do
      text = """
      ## AC Evidence

      - AC 1: i did some work
      """

      # malformed entries are observability-only, not hard fails — the agent
      # didn't claim `verified`, so there's nothing to refute.
      assert GateDValidator.validate(text, %{}) == :ok
    end

    test "collects every failing verified claim, not just the first" do
      text = """
      ## AC Evidence

      - AC 1: verified
      - AC 2: verified
      - AC 3: skipped
      - AC 4: verified
      """

      assert {:fail, failures} = GateDValidator.validate(text, %{})

      assert Enum.map(failures, & &1.ac_id) == ["1", "2", "4"]
      assert Enum.all?(failures, &(&1.reason == :unbacked))
    end
  end

  describe "default_ref_resolver/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gate_d_validator_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, ws: tmp}
    end

    test "treats absent workspace_path as unresolvable for relative refs" do
      assert GateDValidator.default_ref_resolver("lib/foo.ex", %{}) ==
               {:error, :no_workspace}
    end

    test "resolves a non-empty workspace file as :ok", %{ws: ws} do
      path = Path.join(ws, "lib/foo.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "defmodule Foo do\nend\n")

      assert GateDValidator.default_ref_resolver("lib/foo.ex", %{workspace_path: ws}) == :ok
      assert GateDValidator.default_ref_resolver("lib/foo.ex:5", %{workspace_path: ws}) == :ok
    end

    test "rejects an empty workspace file", %{ws: ws} do
      path = Path.join(ws, "empty.ex")
      File.write!(path, "")

      assert GateDValidator.default_ref_resolver("empty.ex", %{workspace_path: ws}) ==
               {:error, :empty}
    end

    test "rejects a missing workspace file", %{ws: ws} do
      assert GateDValidator.default_ref_resolver("nope.ex", %{workspace_path: ws}) ==
               {:error, :missing}
    end

    test "rejects a directory ref (not a regular file)", %{ws: ws} do
      dir = Path.join(ws, "subdir")
      File.mkdir_p!(dir)

      assert GateDValidator.default_ref_resolver("subdir", %{workspace_path: ws}) ==
               {:error, :not_regular}
    end

    test "treats http(s) refs as :ok (CI cross-check deferred to follow-up)" do
      assert GateDValidator.default_ref_resolver("https://example.com/x", %{}) == :ok
      assert GateDValidator.default_ref_resolver("http://example.com/x", %{}) == :ok
    end
  end
end
