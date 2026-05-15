defmodule SymphonyElixir.Orchestrator.StallScanTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.StallScan

  defp now, do: ~U[2026-05-15 12:00:00Z]

  defp ago(seconds), do: DateTime.add(now(), -seconds, :second)

  describe "find_stalled/3" do
    test "returns entries whose last_agent_timestamp is older than timeout_ms" do
      running = %{
        "iss-1" => %{
          identifier: "SODEV-1",
          last_agent_timestamp: ago(120),
          started_at: ago(200),
          session_id: "sess-1"
        }
      }

      assert [
               %{
                 issue_id: "iss-1",
                 identifier: "SODEV-1",
                 session_id: "sess-1",
                 elapsed_ms: elapsed
               }
             ] = StallScan.find_stalled(running, now(), 60_000)

      assert elapsed >= 119_000 and elapsed <= 121_000
    end

    test "falls back to started_at when last_agent_timestamp is missing" do
      running = %{
        "iss-2" => %{
          identifier: "SODEV-2",
          started_at: ago(300),
          session_id: "sess-2"
        }
      }

      assert [%{issue_id: "iss-2", elapsed_ms: elapsed}] =
               StallScan.find_stalled(running, now(), 60_000)

      assert elapsed >= 299_000 and elapsed <= 301_000
    end

    test "ignores entries whose elapsed_ms is below the timeout" do
      running = %{
        "iss-fresh" => %{
          identifier: "SODEV-FRESH",
          last_agent_timestamp: ago(10),
          started_at: ago(20),
          session_id: "sess-fresh"
        }
      }

      assert StallScan.find_stalled(running, now(), 60_000) == []
    end

    test "skips entries with neither last_agent_timestamp nor started_at" do
      running = %{
        "iss-empty" => %{
          identifier: "SODEV-EMPTY",
          session_id: "sess-empty"
        }
      }

      assert StallScan.find_stalled(running, now(), 60_000) == []
    end

    test "defaults session_id to \"n/a\" and identifier to the issue_id when missing" do
      running = %{
        "iss-bare" => %{
          last_agent_timestamp: ago(120)
        }
      }

      assert [%{issue_id: "iss-bare", identifier: "iss-bare", session_id: "n/a"}] =
               StallScan.find_stalled(running, now(), 60_000)
    end

    test "returns an empty list when running is empty" do
      assert StallScan.find_stalled(%{}, now(), 60_000) == []
    end

    test "skips entries whose value is not a map" do
      running = %{"iss-broken" => :unexpected_atom_value}
      assert StallScan.find_stalled(running, now(), 60_000) == []
    end
  end
end
