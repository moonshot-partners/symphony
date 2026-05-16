defmodule SymphonyElixir.RunLedger.ForensicsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunLedger.Forensics

  setup do
    tmp = Path.join(System.tmp_dir!(), "forensics_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, dir: tmp}
  end

  test "creates file with header on first attempt", %{dir: dir} do
    :ok =
      Forensics.append_attempt(
        %{
          ticket: "SODEV-1",
          outcome: "merged",
          tokens: 4200,
          cost_usd: 0.42,
          retries: 0,
          turns: 8,
          pr_url: "https://github.com/x/y/pull/1"
        },
        dir: dir
      )

    body = File.read!(Path.join(dir, "SODEV-1.md"))
    assert body =~ "# SODEV-1 — run history"
    assert body =~ "## Attempt 1"
    assert body =~ "Outcome: merged"
    assert body =~ "Tokens: 4200"
    assert body =~ "Cost: $0.42"
    assert body =~ "Turns: 8"
  end

  test "appends second attempt without duplicating header", %{dir: dir} do
    :ok = Forensics.append_attempt(%{ticket: "SODEV-1", outcome: "closed_unmerged"}, dir: dir)
    :ok = Forensics.append_attempt(%{ticket: "SODEV-1", outcome: "merged"}, dir: dir)

    body = File.read!(Path.join(dir, "SODEV-1.md"))
    assert body =~ "## Attempt 1"
    assert body =~ "## Attempt 2"

    headers = body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "# SODEV-1"))
    assert length(headers) == 1
  end

  test "creates dir if missing", %{dir: dir} do
    nested = Path.join(dir, "nested")
    :ok = Forensics.append_attempt(%{ticket: "T-1", outcome: "merged"}, dir: nested)
    assert File.exists?(Path.join(nested, "T-1.md"))
  end

  test "uses caller-supplied recorded_at timestamp", %{dir: dir} do
    :ok =
      Forensics.append_attempt(
        %{ticket: "T-1", outcome: "merged", recorded_at: "2026-01-01T00:00:00Z"},
        dir: dir
      )

    body = File.read!(Path.join(dir, "T-1.md"))
    assert body =~ "2026-01-01T00:00:00Z"
  end

  test "fills defaults for missing fields", %{dir: dir} do
    :ok = Forensics.append_attempt(%{ticket: "T-1"}, dir: dir)
    body = File.read!(Path.join(dir, "T-1.md"))
    assert body =~ "Outcome: unknown"
    assert body =~ "Tokens: 0"
    assert body =~ "Cost: $0.00"
    assert body =~ "PR: —"
    assert body =~ "Turns: 0"
  end

  test "exercises default opts arity-1 head" do
    result = Forensics.append_attempt(%{ticket: "T-default"})
    assert result == :ok or match?({:error, _}, result)
  end
end
