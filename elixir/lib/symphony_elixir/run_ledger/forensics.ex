defmodule SymphonyElixir.RunLedger.Forensics do
  @moduledoc """
  Per-ticket markdown forensics. Appends one `## Attempt N` block per run to
  `state/runs/<ticket_id>.md`.

  Purpose: agents reading this file on retry know prior context (what failed,
  reviewer feedback, cost) without re-investigation. First call creates the
  file with a `# <ticket_id> — run history` header; subsequent calls just
  append new `## Attempt N` blocks.
  """

  @default_dir "/opt/symphony/state/runs"

  @spec append_attempt(map(), keyword()) :: :ok | {:error, term()}
  def append_attempt(%{ticket: ticket} = run, opts \\ []) when is_binary(ticket) do
    dir = Keyword.get(opts, :dir, @default_dir)
    path = Path.join(dir, "#{ticket}.md")

    with :ok <- File.mkdir_p(dir),
         attempt_num = next_attempt_number(path),
         header = file_header(path, ticket),
         body = render(run, attempt_num),
         :ok <- File.write(path, header <> body, [:append]) do
      :ok
    end
  end

  defp next_attempt_number(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.count(&String.starts_with?(&1, "## Attempt "))
        |> Kernel.+(1)

      _ ->
        1
    end
  end

  defp file_header(path, ticket) do
    if File.exists?(path), do: "", else: "# #{ticket} — run history\n\n"
  end

  defp render(run, attempt_num) do
    ts = run[:recorded_at] || DateTime.utc_now() |> DateTime.to_iso8601()

    """
    ## Attempt #{attempt_num} — #{ts}
    - Outcome: #{run[:outcome] || "unknown"}
    - Tokens: #{run[:tokens] || 0}
    - Cost: $#{format_cost(run[:cost_usd])}
    - Retries: #{run[:retries] || 0}
    - Turns: #{run[:turns] || 0}
    - PR: #{run[:pr_url] || "—"}

    """
  end

  defp format_cost(nil), do: "0.00"

  defp format_cost(c) when is_number(c) do
    "~.2f" |> :io_lib.format([c * 1.0]) |> IO.iodata_to_binary()
  end
end
