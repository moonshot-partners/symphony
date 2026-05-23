defmodule SymphonyElixir.Orchestrator.Reconcilers do
  @moduledoc """
  Bundles every tick-level reconciler the orchestrator fires from
  `maybe_dispatch/1`. Today: `PrMerge` (sweeps PR-attached completed
  issues for merge) and `PromoteToStaging` (operator-triggered
  promote-to-staging flow, SYM-9).

  Extracted so adding the next reconciler is a one-line change here,
  not in `orchestrator.ex` — keeps the orchestrator under its size
  budget and makes the tick fan-out explicit.
  """

  alias SymphonyElixir.Orchestrator.{PrMerge, PromoteToStaging}

  @spec tick() :: :ok
  def tick do
    PrMerge.reconcile()
    PromoteToStaging.reconcile()
    :ok
  end
end
