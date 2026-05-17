defmodule SymphonyElixir.Orchestrator.PreDispatch do
  @moduledoc """
  Deterministic input quality gate. Runs after `DispatchGate.revalidate`
  and before agent spawn.

  Two-step API:

    * `check/1` — pure predicate, no I/O. Returns `:ok` or
      `{:reject, code, message}`.
    * `apply_reject/3` — caller-driven side effects on reject: post a
      comment to the tracker and move the issue to the configured
      `tracker.on_reject_state`. The caller is responsible for any
      `State` field updates (e.g. marking the issue completed).

  Current rule set (kept intentionally minimal — degenerate inputs only):

    * `:empty_description` — description is `nil`, `""`, or whitespace-only.

  Anything richer (vague AC, scope-mismatched labels) is left to the
  prompt-level BLOCKED template in `AGENTS.md` until empirical evidence
  justifies adding another rule here.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{RunningEntry, StateTransition}

  @type reject_reason :: :empty_description
  @type result :: :ok | {:reject, reject_reason(), String.t()}

  @spec check(Issue.t() | term()) :: result()
  def check(%Issue{description: nil}), do: empty_description_reject()

  def check(%Issue{description: description}) when is_binary(description) do
    case String.trim(description) do
      "" -> empty_description_reject()
      _ -> :ok
    end
  end

  def check(_other), do: :ok

  @spec apply_reject(Issue.t(), reject_reason(), String.t()) :: :ok
  def apply_reject(%Issue{} = issue, reason_code, reason_msg)
      when is_atom(reason_code) and is_binary(reason_msg) do
    Logger.info("Pre-dispatch reject: #{RunningEntry.format_context(issue)} reason=#{reason_code}")

    body = """
    ## Pre-dispatch reject — #{reason_code}

    #{reason_msg}
    """

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      case Tracker.create_comment(issue.id, body) do
        {:ok, _comment_id} ->
          :ok

        {:error, reason} ->
          Logger.warning("Pre-dispatch reject comment failed: #{RunningEntry.format_context(issue)} reason=#{inspect(reason)}")
      end
    end)

    StateTransition.apply(issue, Config.settings!().tracker.on_reject_state)
    :ok
  end

  defp empty_description_reject do
    {:reject, :empty_description,
     "description is empty — agent cannot extract acceptance criteria. " <>
       "Add a description with binary pass/fail AC, then move the issue back " <>
       "to the dispatch queue."}
  end
end
