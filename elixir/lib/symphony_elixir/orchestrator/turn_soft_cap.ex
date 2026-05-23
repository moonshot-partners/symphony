defmodule SymphonyElixir.Orchestrator.TurnSoftCap do
  @moduledoc """
  Preemptive turn-cap observer (SYM-22). Fires on `:turn_completed` and
  emits at most one *warning* comment when `turn_count / max_turns` crosses
  `agent.soft_cap_ratio` (default 0.80), then at most one *exhaust* comment
  when `turn_count` reaches `agent.max_turns`. Idempotent via
  `soft_cap_warned` and `soft_cap_exhausted` flags on the running entry.

  Pure decision lives in `evaluate/2` — it does not perform side-effects so
  it can be tested without Linear stubs. `maybe_emit/3` glues the decision
  to the Linear comment + state transition and returns the updated
  running_entry for the orchestrator to thread through `state.running`.
  """

  require Logger

  alias SymphonyElixir.{Config, GitHubPr, Tracker}
  alias SymphonyElixir.Orchestrator.StateTransition

  @type settings :: map()

  @type decision ::
          :noop
          | {:warn, String.t(), map()}
          | {:exhaust, String.t(), map()}

  @spec evaluate(map(), settings()) :: decision()
  def evaluate(running_entry, settings) do
    enabled? = Map.get(settings, :enabled, false)
    ratio = Map.get(settings, :ratio, 0.0)
    max_turns = Map.get(settings, :max_turns, 0)

    if enabled? and is_number(ratio) and is_integer(max_turns) and max_turns > 0 do
      evaluate_enabled(running_entry, ratio, max_turns)
    else
      :noop
    end
  end

  defp evaluate_enabled(running_entry, ratio, max_turns) do
    turn_count = Map.get(running_entry, :turn_count, 0) || 0
    threshold = ratio |> Kernel.*(max_turns) |> Float.ceil() |> trunc()
    phase = phase_for(running_entry, turn_count, max_turns, threshold)
    decision(phase, running_entry, turn_count, max_turns)
  end

  defp phase_for(running_entry, turn_count, max_turns, threshold) do
    cond do
      Map.get(running_entry, :soft_cap_exhausted, false) -> :noop
      turn_count >= max_turns -> :exhaust
      turn_count >= threshold and not Map.get(running_entry, :soft_cap_warned, false) -> :warn
      true -> :noop
    end
  end

  defp decision(:noop, _entry, _turn, _max), do: :noop

  defp decision(:warn, entry, turn, max),
    do: {:warn, warn_message(turn, max), Map.put(entry, :soft_cap_warned, true)}

  defp decision(:exhaust, entry, turn, max),
    do: {:exhaust, exhaust_message(turn, max), Map.put(entry, :soft_cap_exhausted, true)}

  @doc """
  Side-effecting entry point — evaluates the running_entry against the
  configured soft-cap settings, posts the warn/exhaust comment to the
  workpad (threaded under the workpad parent comment when present), and on
  exhaust routes the issue to one of the tracker states.

  SYM-13 AC2: routing differentiates by PR status to keep `on_exhaust_state`
  honest:

    * PR attached AND `GitHubPr.ready?/1` (CI green or PR merged) →
      `tracker.on_exhaust_state || tracker.on_reject_state`. The agent
      shipped code that passed CI but ran out of turns finishing QA /
      polish — "done, environment-blocked", not a rejection.
    * Otherwise (no PR, or PR with red/pending CI) →
      `tracker.on_reject_state`. Without green CI evidence the exhaust
      could just be the agent flailing; refuse to grant the env-blocked
      classification.

  Returns the updated running entry.
  """
  @spec maybe_emit(map(), map(), String.t()) :: map()
  def maybe_emit(running_entry, %{event: :turn_completed}, issue_id) do
    settings = current_settings()

    case evaluate(running_entry, settings) do
      :noop ->
        running_entry

      {:warn, message, updated} ->
        publish_warn(issue_id, message, updated)
        updated

      {:exhaust, message, updated} ->
        publish_exhaust(issue_id, message, updated)
        updated
    end
  end

  def maybe_emit(running_entry, _update, _issue_id), do: running_entry

  defp current_settings do
    settings = Config.settings!().agent

    %{
      enabled: settings.soft_cap_enabled,
      ratio: settings.soft_cap_ratio,
      max_turns: settings.max_turns
    }
  end

  defp warn_message(turn_count, max_turns) do
    """
    ## Approaching turn cap — #{turn_count}/#{max_turns} turns used

    Wrap up the current task: finalize commits, open the PR, write the QA
    self-review if applicable. Do not start new exploration. The run will
    halt once `max_turns` is reached.
    """
  end

  defp exhaust_message(turn_count, max_turns) do
    """
    ## Time-exhausted at turn cap — #{turn_count}/#{max_turns}

    The agent reached `agent.max_turns` without completing the task. This
    is a time-exhaustion exit, not a code-quality rejection. Inspect the
    workpad and the agent's last message to decide whether to extend
    `max_turns`, narrow the ticket scope, or close it manually.
    """
  end

  defp publish_warn(issue_id, body, running_entry) do
    publish_comment(issue_id, body, running_entry, "soft-cap warn")
  end

  defp publish_exhaust(issue_id, body, running_entry) do
    publish_comment(issue_id, body, running_entry, "soft-cap exhaust")

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      tracker = Config.settings!().tracker

      case Map.get(running_entry, :issue) do
        nil -> :ok
        issue -> StateTransition.apply(issue, exhaust_target(issue, tracker))
      end
    end)
  end

  @doc false
  @spec exhaust_target(map(), map()) :: String.t() | nil
  def exhaust_target(issue, tracker) do
    if env_blocked_eligible?(issue) do
      tracker.on_exhaust_state || tracker.on_reject_state
    else
      tracker.on_reject_state
    end
  end

  defp env_blocked_eligible?(issue) do
    Map.get(issue, :has_pr_attachment) == true and GitHubPr.ready?(issue)
  end

  defp publish_comment(issue_id, body, running_entry, label) do
    parent_id = Map.get(running_entry, :workpad_comment_id)
    opts = if is_binary(parent_id), do: [parent_id: parent_id], else: []
    identifier = Map.get(running_entry, :identifier, issue_id)

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      case Tracker.create_comment(issue_id, body, opts) do
        {:ok, comment_id} ->
          Logger.info("TurnSoftCap #{label} posted comment=#{comment_id} issue=#{identifier}")

        {:error, reason} ->
          Logger.warning("TurnSoftCap #{label} post failed issue=#{identifier} reason=#{inspect(reason)}")
      end
    end)
  end
end
