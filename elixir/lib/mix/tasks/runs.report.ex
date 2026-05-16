defmodule Mix.Tasks.Runs.Report do
  use Mix.Task

  @shortdoc "Render markdown summary of /opt/symphony/state/runs.jsonl"

  @moduledoc """
  Reads the run ledger and writes a markdown summary.

  Usage:

      mix runs.report
      mix runs.report --input /path/to/runs.jsonl --output SYMPHONY_RUNS.md

  Defaults:
    --input   /opt/symphony/state/runs.jsonl
    --output  SYMPHONY_RUNS.md
  """

  alias SymphonyElixir.RunLedger.Report

  @default_input "/opt/symphony/state/runs.jsonl"
  @default_output "SYMPHONY_RUNS.md"

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

    File.write!(output, Report.render(runs))
    Mix.shell().info("Wrote #{output} (#{length(runs)} runs from #{input})")
  end
end
