defmodule SymphonyElixir.Orchestrator.RetryAttempts do
  @moduledoc """
  Retry-attempt bookkeeping for `SymphonyElixir.Orchestrator`
  extracted in CP21. Wraps the `state.retry_attempts` map with the
  two operations the orchestrator drives:

    * `schedule/5` — cancel any previous timer for the issue, compute
      the next attempt's delay via `RetryPlan`, send `{:retry_issue,
      issue_id, retry_token}` to `recipient` after the delay, and
      store the freshly armed entry on `state.retry_attempts`.
    * `pop/3` — look up the entry for an `issue_id`+`retry_token`
      pair and return `{:ok, attempt, metadata, new_state}` (entry
      deleted) when the token still matches the latest schedule, or
      `:missing` when a newer schedule has superseded it.

  The recipient pid is threaded explicitly so the sibling never
  captures `self()` and can be exercised against an arbitrary
  process in tests.
  """

  require Logger

  alias SymphonyElixir.Orchestrator.{RetryPlan, State}

  @doc """
  Arm a retry timer for `issue_id`, replacing any previously-armed
  retry entry. Returns the updated `%State{}` with the new retry
  bookkeeping under `state.retry_attempts[issue_id]`.
  """
  @spec schedule(State.t(), String.t(), term(), map(), pid()) :: State.t()
  def schedule(%State{} = state, issue_id, attempt, metadata, recipient)
      when is_binary(issue_id) and is_map(metadata) and is_pid(recipient) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = RetryPlan.delay_ms(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = RetryPlan.pick_identifier(issue_id, previous_retry, metadata)
    error = RetryPlan.pick_error(previous_retry, metadata)
    worker_host = RetryPlan.pick_worker_host(previous_retry, metadata)
    workspace_path = RetryPlan.pick_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(recipient, {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  @doc """
  Look up the retry bookkeeping for `issue_id` and verify it still
  matches the delivered `retry_token`. Returns `{:ok, attempt,
  metadata, new_state}` (entry deleted) when the tokens match, or
  `:missing` when the entry was cleared or replaced by a newer
  schedule (stale timer delivery).
  """
  @spec pop(State.t(), String.t(), reference()) ::
          {:ok, non_neg_integer(), map(), State.t()} | :missing
  def pop(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end
end
