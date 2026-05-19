defmodule SymphonyElixir.Orchestrator.RetryAttempts do
  @moduledoc """
  Retry-attempt bookkeeping for `SymphonyElixir.Orchestrator`
  extracted in CP21. Wraps the `state.retry_attempts` map with the
  two operations the orchestrator drives:

    * `schedule/5` — cancel any previous timer for the issue, compute
      the next attempt's delay via `RetryPlan`, send `{:retry_issue,
      issue_id, retry_token}` to `recipient` after the delay, and
      store the freshly armed entry on `state.retry_attempts`.
      Returns `{:armed, state}` when a timer was set, or
      `{:halted, state}` when `max_retries` was exceeded — so the
      caller can apply tracker side-effects (comment + state move)
      without this pure module performing I/O.
    * `pop/3` — look up the entry for an `issue_id`+`retry_token`
      pair and return `{:ok, attempt, metadata, new_state}` (entry
      deleted) when the token still matches the latest schedule, or
      `:missing` when a newer schedule has superseded it.

  The recipient pid is threaded explicitly so the sibling never
  captures `self()` and can be exercised against an arbitrary
  process in tests.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.{RetryPlan, State}

  @circuit_breaker_threshold 3

  @doc """
  Arm a retry timer for `issue_id`, replacing any previously-armed
  retry entry. Returns `{:armed, state}` with the new retry
  bookkeeping under `state.retry_attempts[issue_id]`.

  When `next_attempt` exceeds `agent.max_retries`, no timer is armed,
  the previous retry entry is cleared, a warning is logged, and
  `{:halted, state}` is returned so the caller can post a tracker
  comment and move the issue to its reject state.
  """
  @spec schedule(State.t(), String.t(), term(), map(), pid()) ::
          {:armed | :halted, State.t()}
  def schedule(%State{} = state, issue_id, attempt, metadata, recipient)
      when is_binary(issue_id) and is_map(metadata) and is_pid(recipient) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    max_retries = Config.settings!().agent.max_retries
    same_error_count = next_same_error_count(previous_retry, metadata)

    cond do
      next_attempt > max_retries ->
        {:halted, halt_retry(state, issue_id, previous_retry, next_attempt, max_retries, metadata, :cap)}

      same_error_count >= @circuit_breaker_threshold ->
        {:halted, halt_retry(state, issue_id, previous_retry, next_attempt, max_retries, metadata, :circuit_breaker)}

      true ->
        {:armed, arm_retry(state, issue_id, previous_retry, next_attempt, metadata, same_error_count, recipient)}
    end
  end

  defp next_same_error_count(previous_retry, metadata) do
    prev_error = Map.get(previous_retry, :error)
    new_error = Map.get(metadata, :error)

    if is_binary(prev_error) and is_binary(new_error) and prev_error == new_error do
      Map.get(previous_retry, :consecutive_same_error_count, 1) + 1
    else
      1
    end
  end

  defp halt_retry(state, issue_id, previous_retry, next_attempt, max_retries, metadata, reason) do
    old_timer = Map.get(previous_retry, :timer_ref)
    if is_reference(old_timer), do: Process.cancel_timer(old_timer)

    identifier = RetryPlan.pick_identifier(issue_id, previous_retry, metadata)
    error = RetryPlan.pick_error(previous_retry, metadata)
    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    case reason do
      :cap ->
        Logger.warning("Retry cap reached issue_id=#{issue_id} issue_identifier=#{identifier} attempt=#{next_attempt} cap=#{max_retries}#{error_suffix}; not arming further retries")

      :circuit_breaker ->
        Logger.warning(
          "Circuit breaker tripped issue_id=#{issue_id} issue_identifier=#{identifier} attempt=#{next_attempt} consecutive_same_error_count=#{@circuit_breaker_threshold}#{error_suffix}; not arming further retries"
        )
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp arm_retry(state, issue_id, previous_retry, next_attempt, metadata, same_error_count, recipient) do
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
            workspace_path: workspace_path,
            consecutive_same_error_count: same_error_count
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
