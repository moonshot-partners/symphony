defmodule SymphonyElixir.RunLedger.WeeklyReport do
  @moduledoc """
  Renders a weekly KPI markdown summary from the run ledger (`runs.jsonl`).

  Sibling of `SymphonyElixir.RunLedger.Report` — that one is an all-time
  outcome dump; this one is the operator-facing weekly scorecard. It works
  on the last 7 days of runs and reports the metrics that the ledger can
  answer exactly with no network call: rework rate, agent cost, time to
  verify, effort, and the run-outcome mix.

  Ticket *completion* (merged / released) is deliberately not computed
  here. A run is recorded when the agent finishes, which is before the
  human merge — the ledger never observes the merge. Completion lives in
  Linear, so the report points operators there instead of guessing.

  All functions are pure. Inputs are tolerated loosely: runs are
  string-keyed maps as parsed from JSONL, and a run with an unparseable
  `recorded_at` is dropped rather than crashing the report.
  """

  # Claude Sonnet 4.6 standard API pricing, USD per million tokens
  # (verified 2026-05). Update both constants if the agent model or its
  # pricing changes — the cost figures below depend only on these.
  @usd_per_mtok_in 3.0
  @usd_per_mtok_out 15.0

  @window_days 7

  @spec render([map()]) :: String.t()
  def render(runs) when is_list(runs), do: render(runs, DateTime.utc_now())

  @spec render([map()], DateTime.t()) :: String.t()
  def render(runs, now) when is_list(runs) do
    window_start = DateTime.add(now, -@window_days * 24 * 3600, :second)

    in_window =
      Enum.filter(runs, fn run ->
        is_map(run) &&
          case parse_dt(Map.get(run, "recorded_at")) do
            %DateTime{} = dt -> DateTime.compare(dt, window_start) != :lt
            nil -> false
          end
      end)

    if in_window == [] do
      empty_report(window_start, now)
    else
      IO.iodata_to_binary([
        header(window_start, now),
        summary(in_window),
        initiator_breakdown(in_window),
        time_to_verify(in_window),
        effort(in_window),
        outcomes(in_window),
        per_ticket(in_window, now),
        completion_note(),
        deferred_metrics()
      ])
    end
  end

  defp empty_report(window_start, now) do
    """
    # Symphony weekly report

    Window: #{date(window_start)} to #{date(now)}

    No runs in the last 7 days.
    """
  end

  defp header(window_start, now) do
    """
    # Symphony weekly report

    Window: #{date(window_start)} to #{date(now)} (last 7 days)

    """
  end

  defp summary(runs) do
    tickets = distinct_tickets(runs)
    ticket_count = map_size(tickets)
    reworked = Enum.count(tickets, fn {_ticket, runs} -> length(runs) > 1 end)
    rework_pct = percent(reworked, ticket_count)
    rework_after_review = count_rework_after_review(tickets)
    rework_after_review_pct = percent(rework_after_review, ticket_count)
    cost = total_cost(runs)
    per_ticket_cost = if ticket_count > 0, do: cost / ticket_count, else: 0.0

    """
    ## Summary

    - Runs: #{length(runs)}
    - Tickets worked: #{ticket_count}
    - Rework rate: #{rework_pct}% (#{reworked} of #{ticket_count} tickets needed more than one pass)
    - Rework after review: #{rework_after_review_pct}% (#{rework_after_review} of #{ticket_count} tickets re-dispatched after a PR was opened — human jump-in proxy)
    - Estimated agent cost: $#{usd(cost)}
    - Cost per ticket worked: $#{usd(per_ticket_cost)}

    """
  end

  defp initiator_breakdown(runs) do
    tickets_by_initiator =
      runs
      |> distinct_tickets()
      |> Enum.map(fn {ticket, ticket_runs} -> {ticket, latest_initiator(ticket_runs)} end)

    total = length(tickets_by_initiator)

    rows =
      tickets_by_initiator
      |> Enum.frequencies_by(fn {_ticket, initiator} -> initiator end)
      |> Enum.sort_by(fn {_initiator, count} -> -count end)
      |> Enum.map_join("\n", fn {initiator, count} ->
        "- #{initiator || "(unknown)"}: #{count} ticket#{plural(count)} (#{percent(count, total)}%)"
      end)

    """
    ## Initiator breakdown

    Who created the Linear ticket the agent worked. Per Juan's KPI ask
    (\"what we don't measure we can't improve\") and Marianna's
    attribution question — track the human authorship even before the
    GitHub App lands.

    #{rows}

    """
  end

  defp count_rework_after_review(tickets) do
    Enum.count(tickets, fn {_ticket, ticket_runs} ->
      sorted = sort_by_recorded_at(ticket_runs)

      sorted
      |> Enum.drop(-1)
      |> Enum.any?(fn run -> Map.get(run, "outcome") == "pr_open" end)
    end)
  end

  defp latest_initiator(ticket_runs) do
    ticket_runs
    |> sort_by_recorded_at()
    |> List.last()
    |> Map.get("initiator")
  end

  defp sort_by_recorded_at(ticket_runs) do
    Enum.sort_by(ticket_runs, &Map.get(&1, "recorded_at", ""))
  end

  defp time_to_verify(runs) do
    durations =
      runs
      |> Enum.map(&run_duration_seconds/1)
      |> Enum.reject(&is_nil/1)

    excluded = length(runs) - length(durations)

    body =
      if durations == [] do
        "No run in this window carries the timestamps needed to measure duration."
      else
        avg = round(Enum.sum(durations) / length(durations) / 60)
        med = round(median(durations) / 60)

        [
          "- Average: #{avg} min\n",
          "- Median: #{med} min",
          if(excluded > 0, do: "\n- #{excluded} run#{plural(excluded)} excluded (no start timestamp)", else: "")
        ]
      end

    """
    ## Time to verify

    Run duration from dispatch to the agent finishing its pull request.

    #{IO.iodata_to_binary(body)}

    """
  end

  defp effort(runs) do
    total_turns = sum_field(runs, "turns")
    total_retries = sum_field(runs, "retries")
    avg_turns = Float.round(total_turns / length(runs), 1)

    """
    ## Effort

    - Total turns: #{total_turns}
    - Average turns per run: #{avg_turns}
    - Retries: #{total_retries}

    """
  end

  defp outcomes(runs) do
    rows =
      runs
      |> Enum.frequencies_by(&Map.get(&1, "outcome", "unknown"))
      |> Enum.sort_by(fn {_outcome, count} -> -count end)
      |> Enum.map_join("\n", fn {outcome, count} -> "- #{outcome}: #{count}" end)

    """
    ## Run outcomes

    #{rows}

    """
  end

  defp per_ticket(runs, now) do
    rows =
      runs
      |> distinct_tickets()
      |> Enum.sort_by(fn {_ticket, ticket_runs} -> -length(ticket_runs) end)
      |> Enum.map_join("\n", &per_ticket_row(&1, now))

    """
    ## Per ticket

    | Ticket | Initiator | Passes | Turns | Tokens | Cost | Last outcome | Time in review |
    |---|---|---|---|---|---|---|---|
    #{rows}

    """
  end

  defp per_ticket_row({ticket, ticket_runs}, now) do
    turns = sum_field(ticket_runs, "turns")
    tokens = sum_field(ticket_runs, "tokens")
    cost = total_cost(ticket_runs)
    last = last_outcome(ticket_runs)
    initiator = latest_initiator(ticket_runs) || "—"
    time_in_review = time_in_review_for(ticket_runs, now)

    "| #{ticket} | #{initiator} | #{length(ticket_runs)} | #{turns} | #{tokens} | $#{usd(cost)} | #{last} | #{time_in_review} |"
  end

  defp time_in_review_for(ticket_runs, now) do
    # Time-in-code-review is approximated by the lifetime of the most recent
    # `pr_open` run for the ticket. Symphony moves the ticket to the configured
    # `tracker.on_complete_state` ("In Code Review") at the moment the PR
    # attaches, so `recorded_at` of the latest `pr_open` is a reliable lower
    # bound. Once the PR is merged/closed the column entry is no longer "in
    # review", so we omit the value.
    latest = ticket_runs |> sort_by_recorded_at() |> List.last()

    # Window-filter guarantees a parseable `recorded_at` for every run reaching
    # this path, so the only branch that returns "—" is the non-pr_open case.
    if Map.get(latest, "outcome") == "pr_open" do
      latest |> Map.get("recorded_at") |> parse_dt() |> format_duration_from(now)
    else
      "—"
    end
  end

  defp format_duration_from(%DateTime{} = dt, now) do
    seconds = max(0, DateTime.diff(now, dt, :second))
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp completion_note do
    """
    ## Ticket completion

    A run is recorded when the agent finishes, which is before a human
    reviews and merges the pull request. The ledger therefore cannot see
    whether a ticket was completed, accepted, or later reverted.

    For completion, acceptance, and revert counts, read the Linear board
    filtered to the `agent` label and group by state.

    """
  end

  defp deferred_metrics do
    """
    ## Future metrics (deferred)

    "% of the backlog Symphony can realistically take" was flagged by
    Marianna herself in the 2026-05-20 session as too early to measure
    now. Tracked in SYM-6 as out-of-scope; revisit once the agent has run
    on enough mixed tickets to establish a reliable success rate per
    ticket archetype.
    """
  end

  defp distinct_tickets(runs) do
    Enum.group_by(runs, &Map.get(&1, "ticket", "(unknown)"))
  end

  defp last_outcome(runs) do
    runs
    |> Enum.max_by(fn run -> Map.get(run, "recorded_at", "") end, fn -> %{} end)
    |> Map.get("outcome", "—")
  end

  defp run_duration_seconds(run) do
    with %DateTime{} = started <- parse_dt(Map.get(run, "started_at")),
         %DateTime{} = recorded <- parse_dt(Map.get(run, "recorded_at")) do
      max(0, DateTime.diff(recorded, started, :second))
    else
      _ -> nil
    end
  end

  defp total_cost(runs) do
    Enum.reduce(runs, 0.0, fn run, acc ->
      acc + run_cost(field_int(run, "tokens_in"), field_int(run, "tokens_out"))
    end)
  end

  defp run_cost(tokens_in, tokens_out) do
    tokens_in / 1_000_000 * @usd_per_mtok_in + tokens_out / 1_000_000 * @usd_per_mtok_out
  end

  defp sum_field(runs, key) do
    Enum.reduce(runs, 0, fn run, acc -> acc + field_int(run, key) end)
  end

  defp field_int(run, key) do
    case Map.get(run, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp percent(count, total), do: round(count / total * 100)

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp usd(amount), do: :erlang.float_to_binary(amount * 1.0, decimals: 2)

  defp date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
