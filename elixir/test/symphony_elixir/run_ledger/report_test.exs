defmodule SymphonyElixir.RunLedger.ReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunLedger.Report

  describe "render/1" do
    test "returns header note when ledger is empty" do
      out = Report.render([])
      assert out =~ "# Symphony Runs Report"
      assert out =~ "No runs recorded yet"
    end

    test "summarizes total runs and outcome counts" do
      runs = [
        %{"ticket" => "T-1", "outcome" => "merged", "tokens" => 100, "recorded_at" => "2026-05-16T01:00:00Z"},
        %{"ticket" => "T-2", "outcome" => "closed_unmerged", "tokens" => 50, "recorded_at" => "2026-05-16T02:00:00Z"},
        %{"ticket" => "T-3", "outcome" => "merged", "tokens" => 200, "recorded_at" => "2026-05-16T03:00:00Z"},
        %{"ticket" => "T-1", "outcome" => "no_pr", "tokens" => 10, "recorded_at" => "2026-05-16T04:00:00Z"}
      ]

      out = Report.render(runs)
      assert out =~ "Total runs: 4"
      assert out =~ "merged: 2"
      assert out =~ "closed_unmerged: 1"
      assert out =~ "no_pr: 1"
    end

    test "top tickets table shows attempt counts in descending order" do
      runs = [
        %{"ticket" => "T-1", "outcome" => "no_pr", "recorded_at" => "2026-05-16T01:00:00Z"},
        %{"ticket" => "T-1", "outcome" => "no_pr", "recorded_at" => "2026-05-16T02:00:00Z"},
        %{"ticket" => "T-1", "outcome" => "merged", "recorded_at" => "2026-05-16T03:00:00Z"},
        %{"ticket" => "T-2", "outcome" => "merged", "recorded_at" => "2026-05-16T04:00:00Z"}
      ]

      out = Report.render(runs)
      assert out =~ "## Top tickets by attempt count"
      idx_t1 = :binary.match(out, "T-1") |> elem(0)
      idx_t2 = :binary.match(out, "T-2") |> elem(0)
      assert idx_t1 < idx_t2
    end

    test "recent runs section shows latest 10 in reverse chronological order" do
      runs =
        for i <- 1..15 do
          %{
            "ticket" => "T-#{i}",
            "outcome" => "merged",
            "recorded_at" => "2026-05-#{String.pad_leading("#{i}", 2, "0")}T00:00:00Z"
          }
        end

      out = Report.render(runs)
      assert out =~ "## Recent runs"
      assert out =~ "T-15"
      assert out =~ "T-6"
      refute out =~ "T-5\b"
    end

    test "ignores malformed entries without crashing" do
      runs = [
        %{"ticket" => "T-1", "outcome" => "merged"},
        "garbage line",
        nil,
        %{"ticket" => "T-2", "outcome" => "no_pr"}
      ]

      out = Report.render(runs)
      assert out =~ "Total runs: 2"
    end
  end

  describe "parse_lines/1" do
    test "parses one JSON object per line, skips blanks and invalid lines" do
      input = ~s({"ticket":"T-1","outcome":"merged"}\n\nnot json\n{"ticket":"T-2","outcome":"no_pr"}\n)

      assert [%{"ticket" => "T-1"}, %{"ticket" => "T-2"}] = Report.parse_lines(input)
    end
  end
end
