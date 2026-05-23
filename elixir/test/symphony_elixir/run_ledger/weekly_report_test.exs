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

      assert out =~ "- Runs: 1\n"
      assert out =~ "SODEV-NEW"
      refute out =~ "SODEV-OLD"
    end

    test "excludes runs with an unparseable recorded_at" do
      runs = [run(%{"recorded_at" => "not-a-date"}), run(%{"ticket" => "SODEV-2"})]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "- Runs: 1\n"
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
      assert out =~ "- Runs: 3\n"
      assert out =~ "- Tickets worked: 2\n"
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
      assert out =~ "(1 of 3 tickets"
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
      assert out =~ "- 1 run excluded"
    end

    test "the excluded-run count is pluralized when more than one is excluded" do
      runs = [
        run(%{"started_at" => nil}),
        run(%{"started_at" => nil}),
        run(%{"started_at" => "2026-05-20T17:00:00Z", "recorded_at" => "2026-05-20T17:10:00Z"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "- 2 runs excluded"
    end

    test "a non-integer token field counts as zero rather than crashing the report" do
      runs = [run(%{"tokens_in" => "bogus", "tokens_out" => nil})]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Estimated agent cost: $0.00"
    end

    test "summarizes run outcomes" do
      runs = [
        run(%{"outcome" => "pr_open"}),
        run(%{"outcome" => "pr_open"}),
        run(%{"outcome" => "no_pr"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "- pr_open: 2\n"
      assert out =~ "- no_pr: 1\n"
    end

    test "per-ticket table carries one row per ticket with attempt count" do
      runs = [
        run(%{"ticket" => "SODEV-1", "turns" => 3}),
        run(%{"ticket" => "SODEV-1", "turns" => 2})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "| SODEV-1 | — | 2 |"
    end

    test "points operators to the Linear board for completion data" do
      out = WeeklyReport.render([run(%{})], @now)
      assert out =~ "## Ticket completion"
      assert out =~ "Linear"
    end
  end

  describe "render/2 — SYM-6 KPI extensions" do
    test "groups tickets by their initiator and shows share of total" do
      # Two tickets attributed to vini, one to mariana, one with no creator —
      # the breakdown must list every initiator with the percent share rounded
      # to whole numbers and sort by descending count.
      runs = [
        run(%{"ticket" => "SODEV-1", "initiator" => "vini"}),
        run(%{"ticket" => "SODEV-2", "initiator" => "vini"}),
        run(%{"ticket" => "SODEV-3", "initiator" => "mariana"}),
        run(%{"ticket" => "SODEV-4", "initiator" => nil})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "## Initiator breakdown"
      assert out =~ "- vini: 2 tickets (50%)"
      assert out =~ "- mariana: 1 ticket (25%)"
      assert out =~ "- (unknown): 1 ticket (25%)"
    end

    test "initiator breakdown uses the latest run's initiator per ticket" do
      runs = [
        run(%{"ticket" => "SODEV-1", "initiator" => "vini", "recorded_at" => "2026-05-19T12:00:00Z"}),
        run(%{"ticket" => "SODEV-1", "initiator" => "mariana", "recorded_at" => "2026-05-20T12:00:00Z"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "- mariana: 1 ticket (100%)"
    end

    test "rework-after-review counts tickets re-dispatched after a pr_open run" do
      # SODEV-A: pr_open then re-dispatch → rework after review.
      # SODEV-B: two runs but neither produced a PR → multi-pass but NOT
      #          rework-after-review.
      # SODEV-C: single pr_open run → not rework.
      runs = [
        run(%{"ticket" => "SODEV-A", "outcome" => "pr_open", "recorded_at" => "2026-05-19T12:00:00Z"}),
        run(%{"ticket" => "SODEV-A", "outcome" => "no_pr", "recorded_at" => "2026-05-20T12:00:00Z"}),
        run(%{"ticket" => "SODEV-B", "outcome" => "no_pr", "recorded_at" => "2026-05-19T12:00:00Z"}),
        run(%{"ticket" => "SODEV-B", "outcome" => "no_pr", "recorded_at" => "2026-05-20T12:00:00Z"}),
        run(%{"ticket" => "SODEV-C", "outcome" => "pr_open"})
      ]

      out = WeeklyReport.render(runs, @now)
      assert out =~ "Rework after review: 33% (1 of 3 tickets"
    end

    test "per-ticket row carries initiator and time-in-review for pr_open tickets" do
      runs = [
        run(%{
          "ticket" => "SODEV-9",
          "initiator" => "vini",
          "outcome" => "pr_open",
          "recorded_at" => "2026-05-20T15:30:00Z"
        })
      ]

      out = WeeklyReport.render(runs, @now)
      # @now is 2026-05-20 18:00:00 → 2h 30m in review.
      assert out =~ "| SODEV-9 | vini | 1 | 1 | 0 | $0.00 | pr_open | 2h 30m |"
    end

    test "time-in-review is em-dash when the latest run did not produce a PR" do
      runs = [run(%{"ticket" => "SODEV-X", "outcome" => "no_pr"})]

      out = WeeklyReport.render(runs, @now)
      # Expect the em-dash placeholder in the time-in-review cell.
      assert out =~ "| SODEV-X | — | 1 | 1 | 0 | $0.00 | no_pr | — |"
    end

    test "deferred-metrics section explicitly defers \"% of backlog\" to SYM-6" do
      out = WeeklyReport.render([run(%{})], @now)
      assert out =~ "## Future metrics (deferred)"
      assert out =~ "% of the backlog"
      assert out =~ "SYM-6"
    end
  end
end
