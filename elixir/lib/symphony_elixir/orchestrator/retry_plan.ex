defmodule SymphonyElixir.Orchestrator.RetryPlan do
  @moduledoc """
  Pure helpers that compute the parameters of a retry attempt for an
  issue tracked by `SymphonyElixir.Orchestrator`.

  Extracted from `SymphonyElixir.Orchestrator` (CP14). These helpers
  cover the math (delay, attempt normalization) and the metadata
  fall-through rules (identifier / error / worker_host / workspace_path
  picked from the just-supplied metadata first, then the previous retry
  entry, then a sensible default).

  None of these functions read or mutate the GenServer state — callers
  hand in the inputs and use the returned value to build the new state
  themselves.
  """

  import Bitwise

  alias SymphonyElixir.Config

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000

  @doc """
  Returns the delay (in milliseconds) before the next retry fires.

  The first continuation retry (attempt == 1, `delay_type: :continuation`
  in metadata) uses the fixed 1_000 ms delay so the agent can pick the
  PR-ready signal up quickly. Every other case uses an exponential
  failure backoff (10_000 ms base, doubling per attempt) clamped at the
  configured `agent.max_retry_backoff_ms`.
  """
  @spec delay_ms(pos_integer(), map()) :: pos_integer()
  def delay_ms(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_delay(attempt)
    end
  end

  defp failure_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  @doc """
  Coerces any input to a non-negative retry attempt counter. Positive
  integers pass through unchanged; anything else (zero, negative, nil,
  non-integer) collapses to 0.
  """
  @spec normalize_attempt(term()) :: non_neg_integer()
  def normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_attempt(_attempt), do: 0

  @doc """
  Returns the attempt counter to use when a running issue terminates
  while it already has a non-zero `retry_attempt`. Returns `nil` when
  there is nothing to bump (no retry_attempt, zero, or non-integer).
  """
  @spec next_attempt_from_running(map()) :: pos_integer() | nil
  def next_attempt_from_running(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  @doc """
  Pick the identifier for the next retry entry: `metadata.identifier`
  wins, then the previous retry's identifier, then the bare `issue_id`
  string.
  """
  @spec pick_identifier(String.t(), map(), map()) :: String.t()
  def pick_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  @doc "Pick the error string for the next retry entry (metadata first, then previous_retry, then nil)."
  @spec pick_error(map(), map()) :: String.t() | nil
  def pick_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  @doc "Pick the worker host for the next retry entry (metadata first, then previous_retry, then nil)."
  @spec pick_worker_host(map(), map()) :: String.t() | nil
  def pick_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  @doc "Pick the workspace path for the next retry entry (metadata first, then previous_retry, then nil)."
  @spec pick_workspace_path(map(), map()) :: String.t() | nil
  def pick_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end
end
