defmodule SymphonyElixir.Orchestrator.PrUrl do
  @moduledoc """
  Parses GitHub pull request URLs into `{owner, repo, number}` tuples.

  Extracted from `SymphonyElixir.Orchestrator` so the regex is testable and
  reusable without exposing a `*_for_test` shim.
  """

  @doc """
  Extracts the owner, repo, and PR number from a GitHub pull-request URL.

  Returns `{:ok, owner, repo, number}` for a recognized URL and `:error`
  for anything else (non-binary input, malformed path, etc.).
  """
  @spec parse(term()) :: {:ok, String.t(), String.t(), pos_integer()} | :error
  def parse(url) when is_binary(url) do
    case Regex.run(~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}, url) do
      [_, owner, repo, number] -> {:ok, owner, repo, String.to_integer(number)}
      _ -> :error
    end
  end

  def parse(_), do: :error
end
