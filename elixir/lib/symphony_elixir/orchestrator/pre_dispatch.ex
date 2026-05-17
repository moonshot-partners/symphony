defmodule SymphonyElixir.Orchestrator.PreDispatch do
  @moduledoc """
  Deterministic input quality gate. Runs after `DispatchGate.revalidate`
  and before agent spawn.

  Pure predicate, no I/O: returns either `:ok` (let dispatch proceed) or
  `{:reject, code, message}` (the caller is responsible for the side
  effects — comment, state transition, log).

  Current rule set (kept intentionally minimal — degenerate inputs only):

    * `:empty_description` — description is `nil`, `""`, or whitespace-only.

  Anything richer (vague AC, scope-mismatched labels) is left to the
  prompt-level BLOCKED template in `AGENTS.md` until empirical evidence
  justifies adding another rule here.
  """

  alias SymphonyElixir.Linear.Issue

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

  defp empty_description_reject do
    {:reject, :empty_description,
     "description is empty — agent cannot extract acceptance criteria. " <>
       "Add a description with binary pass/fail AC, then move the issue back " <>
       "to the dispatch queue."}
  end
end
