defmodule Mix.Tasks.Runs.Weekly do
  use Mix.Task

  @shortdoc "Render the weekly KPI summary of /opt/symphony/state/runs.jsonl"

  @moduledoc """
  Reads the run ledger and writes a weekly KPI markdown report — the
  last 7 days of agent runs scored on rework rate, agent cost, time to
  verify, and effort.

  Usage:

      mix runs.weekly
      mix runs.weekly --input /path/to/runs.jsonl --output SYMPHONY_WEEKLY.md

  Defaults:
    --input   /opt/symphony/state/runs.jsonl
    --output  SYMPHONY_WEEKLY.md
  """

  alias SymphonyElixir.RunLedger.Report
  alias SymphonyElixir.RunLedger.WeeklyReport

  @default_input "/opt/symphony/state/runs.jsonl"
  @default_output "SYMPHONY_WEEKLY.md"

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, strict: [input: :string, output: :string])

    if invalid != [], do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

    input = Keyword.get(opts, :input, @default_input)
    output = Keyword.get(opts, :output, @default_output)

    runs =
      case File.read(input) do
        {:ok, content} -> Report.parse_lines(content)
        {:error, :enoent} -> []
        {:error, reason} -> Mix.raise("Cannot read #{input}: #{inspect(reason)}")
      end

    File.write!(output, WeeklyReport.render(runs))
    Mix.shell().info("Wrote #{output} (#{length(runs)} runs from #{input})")
  end
end
