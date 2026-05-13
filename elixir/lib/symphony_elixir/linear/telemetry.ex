defmodule SymphonyElixir.Linear.Telemetry do
  @moduledoc """
  Atomic counter for Linear API timeouts.

  SODEV-765 surfaced silent Linear timeouts: Logger.error fired, but the
  operator had no aggregated visibility on whether timeouts were rare or
  systemic. This module keeps a single counter (`:counters` backed) that
  callers can read via `count/0` for /status or ops dashboards.
  """

  @counter_key {__MODULE__, :counter}

  @doc """
  Classifies a `{:error, reason}` tuple as a transport timeout. Recognizes
  bare atoms (`:timeout`), Mint/Req-style structs that expose `reason:
  :timeout`, and the wrapper used by `Linear.Client.graphql/3`
  (`{:linear_api_request, :timeout}`).
  """
  @spec timeout_error?(term()) :: boolean()
  def timeout_error?({:error, :timeout}), do: true
  def timeout_error?({:error, %{reason: :timeout}}), do: true
  def timeout_error?({:error, {:linear_api_request, :timeout}}), do: true
  def timeout_error?({:error, {:linear_api_request, %{reason: :timeout}}}), do: true
  def timeout_error?(_), do: false

  @doc """
  Returns the result unchanged. If the result is a recognized timeout,
  increments the counter as a side effect.
  """
  @spec maybe_record_timeout(term()) :: term()
  def maybe_record_timeout(result) do
    if timeout_error?(result), do: record_timeout()
    result
  end

  @doc "Increments the timeout counter by 1."
  @spec record_timeout() :: :ok
  def record_timeout do
    :counters.add(counter_ref(), 1, 1)
    :ok
  end

  @doc "Returns the current timeout count."
  @spec count() :: non_neg_integer()
  def count, do: :counters.get(counter_ref(), 1)

  @doc "Resets the counter to zero. Test-only by convention."
  @spec reset() :: :ok
  def reset do
    ref = counter_ref()
    :counters.put(ref, 1, 0)
    :ok
  end

  defp counter_ref do
    case :persistent_term.get(@counter_key, :undefined) do
      :undefined ->
        ref = :counters.new(1, [:atomics])
        :persistent_term.put(@counter_key, ref)
        ref

      ref ->
        ref
    end
  end
end
