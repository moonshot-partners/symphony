defmodule SymphonyElixir.RunLedger.WeeklyReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunLedger.WeeklyReport

  @now ~U[2026-05-20 18:00:00Z]

  defp run(overrides) do
    Map.merge(
      %{
        "ticket" => "SODEV-1",
        "issue_id" => "lin-1",
        "outcome" => "pr_open",
        "tokens_in" => 0,
        "tokens_out" => 0,
        "tokens" => 0,
        "turns" => 1,
        "retries" => 0,
        "started_at" => "2026-05-20T17:00:00Z",
        "recorded_at" => "2026-05-20T17:30:00Z"
      },
      overrides
    )
  end

  describe "render/2 — empty and windowing" do
    test "reports no runs when the ledger is empty" do
      out = WeeklyReport.render([], @now)
      assert out =~ "# Symphony weekly report"
      assert out =~ "No runs in the last 7 days"
    end

    test "excludes runs older than 7 days from the window" do
      runs = [
        run(%{"ticket" => "SODEV-OLD", "recorded_at" => "2026-05-10T12:00:00Z"}),
        run(%{"ticket" => "SODEV-NEW", "recorded_at" => "2026-05-19T12:00:00Z"})
      ]

      out = WeeklyReport.render(runs, @now)

      assert out =~ "Runs: 1"
      assert out =~ "SODEV-NEW"
      refute out =~ "SODEV-OLD"
    end

    test "excludes runs with an unparseable recorded_at" do
      runs = [run(%{"recorded_at" => "not-a-date"}), run(%{"ticket" => "SODEV-2"})]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Runs: 1"
    end
  end

  describe "render/2 — KPIs" do
    test "counts runs and distinct tickets worked" do
      runs = [
        run(%{"ticket" => "SODEV-1"}),
        run(%{"ticket" => "SODEV-1"}),
        run(%{"ticket" => "SODEV-2"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Runs: 3"
      assert out =~ "Tickets worked: 2"
    end

    test "rework rate is the share of tickets that needed more than one pass" do
      # SODEV-1 has 2 runs (rework), SODEV-2 and SODEV-3 have 1 each.
      runs = [
        run(%{"ticket" => "SODEV-1"}),
        run(%{"ticket" => "SODEV-1"}),
        run(%{"ticket" => "SODEV-2"}),
        run(%{"ticket" => "SODEV-3"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Rework rate: 33%"
      assert out =~ "1 of 3 tickets"
    end

    test "estimates total and per-ticket agent cost at Sonnet 4.6 pricing" do
      # Each run: 1M input @ $3 + 1M output @ $15 = $18. Two distinct
      # tickets -> total $36.00, cost per ticket worked $18.00.
      runs = [
        run(%{"ticket" => "SODEV-1", "tokens_in" => 1_000_000, "tokens_out" => 1_000_000}),
        run(%{"ticket" => "SODEV-2", "tokens_in" => 1_000_000, "tokens_out" => 1_000_000})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Estimated agent cost: $36.00"
      assert out =~ "Cost per ticket worked: $18.00"
    end

    test "time to verify reports both the average and the median duration" do
      # Durations 10, 20, 60 min -> average 30, median 20 (distinct, so
      # neither metric can masquerade as the other).
      runs = [
        run(%{"started_at" => "2026-05-20T17:00:00Z", "recorded_at" => "2026-05-20T17:10:00Z"}),
        run(%{"started_at" => "2026-05-20T17:00:00Z", "recorded_at" => "2026-05-20T17:20:00Z"}),
        run(%{"started_at" => "2026-05-20T17:00:00Z", "recorded_at" => "2026-05-20T18:00:00Z"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Average: 30 min"
      assert out =~ "Median: 20 min"
    end

    test "runs without a started_at are excluded from time to verify" do
      runs = [
        run(%{"started_at" => nil, "recorded_at" => "2026-05-20T17:40:00Z"}),
        run(%{"started_at" => "2026-05-20T17:00:00Z", "recorded_at" => "2026-05-20T17:10:00Z"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Average: 10 min"
      assert out =~ "1 run excluded"
    end

    test "summarizes run outcomes" do
      runs = [
        run(%{"outcome" => "pr_open"}),
        run(%{"outcome" => "pr_open"}),
        run(%{"outcome" => "no_pr"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "pr_open: 2"
      assert out =~ "no_pr: 1"
    end

    test "per-ticket table carries one row per ticket with attempt count" do
      runs = [
        run(%{"ticket" => "SODEV-1", "turns" => 3}),
        run(%{"ticket" => "SODEV-1", "turns" => 2})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "| SODEV-1 | 2 |"
    end

    test "points operators to the Linear board for completion data" do
      out = WeeklyReport.render([run(%{})], @now)
      assert out =~ "## Ticket completion"
      assert out =~ "Linear"
    end
  end
end
