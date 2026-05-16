defmodule SymphonyElixir.RunLedger.Report do
  @moduledoc """
  Pure functions for rendering a markdown summary of `runs.jsonl`.

  Designed for `mix runs.report` and any other caller (test, ad-hoc
  diagnostics) that needs a human-readable aggregate of the per-run
  ledger. Inputs are tolerated loosely — malformed lines and non-map
  entries are skipped so a single bad write never breaks the report.
  """

  @recent_count 10
  @top_tickets_count 10

  @spec parse_lines(String.t()) :: [map()]
  def parse_lines(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end
    end)
  end

  @spec render([map()]) :: String.t()
  def render(runs) when is_list(runs) do
    valid = Enum.filter(runs, &is_map/1)

    cond do
      valid == [] ->
        empty_report()

      true ->
        IO.iodata_to_binary([
          header(length(valid)),
          outcome_summary(valid),
          top_tickets(valid),
          recent_runs(valid)
        ])
    end
  end

  defp empty_report do
    """
    # Symphony Runs Report

    No runs recorded yet.
    """
  end

  defp header(total) do
    """
    # Symphony Runs Report

    Total runs: #{total}

    """
  end

  defp outcome_summary(runs) do
    counts =
      runs
      |> Enum.frequencies_by(&Map.get(&1, "outcome", "unknown"))
      |> Enum.sort_by(fn {_outcome, count} -> -count end)

    rows = Enum.map_join(counts, "\n", fn {outcome, count} -> "- #{outcome}: #{count}" end)

    """
    ## Outcomes

    #{rows}

    """
  end

  defp top_tickets(runs) do
    rows =
      runs
      |> Enum.frequencies_by(&Map.get(&1, "ticket", "(unknown)"))
      |> Enum.sort_by(fn {_ticket, count} -> -count end)
      |> Enum.take(@top_tickets_count)
      |> Enum.map_join("\n", fn {ticket, count} -> "- #{ticket} — #{count} attempt(s)" end)

    """
    ## Top tickets by attempt count

    #{rows}

    """
  end

  defp recent_runs(runs) do
    rows =
      runs
      |> Enum.sort_by(&Map.get(&1, "recorded_at", ""), :desc)
      |> Enum.take(@recent_count)
      |> Enum.map_join("\n", &recent_row/1)

    """
    ## Recent runs

    | Ticket | Outcome | Tokens | Recorded |
    |---|---|---|---|
    #{rows}
    """
  end

  defp recent_row(run) do
    "| #{Map.get(run, "ticket", "—")} | #{Map.get(run, "outcome", "—")} | #{Map.get(run, "tokens", 0)} | #{Map.get(run, "recorded_at", "—")} |"
  end
end
