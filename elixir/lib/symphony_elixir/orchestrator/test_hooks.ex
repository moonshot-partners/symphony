defmodule SymphonyElixir.Orchestrator.TestHooks do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.DispatchGate
  alias SymphonyElixir.Orchestrator.SlotPolicy
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Orchestrator.StateTransition
  alias SymphonyElixir.Orchestrator.WorkerSelector

  @spec should_dispatch_issue(Issue.t(), State.t()) :: boolean()
  def should_dispatch_issue(%Issue{} = issue, %State{} = state) do
    SlotPolicy.should_dispatch?(
      issue,
      state,
      DispatchGate.active_state_set(),
      DispatchGate.terminal_state_set()
    )
  end

  @spec revalidate_issue_for_dispatch(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    DispatchGate.revalidate(issue, issue_fetcher, DispatchGate.terminal_state_set())
  end

  @spec apply_state_transition(Issue.t(), String.t() | nil) :: :ok
  def apply_state_transition(%Issue{} = issue, state_name) do
    StateTransition.apply(issue, state_name)
  end

  @spec select_worker_host(State.t(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host(%State{} = state, preferred_worker_host) do
    WorkerSelector.select(state, preferred_worker_host)
  end
end
