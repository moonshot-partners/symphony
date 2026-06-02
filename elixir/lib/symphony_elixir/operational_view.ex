defmodule SymphonyElixir.OperationalView do
  @moduledoc """
  Boundary for optional human-facing operational surfaces.

  The orchestrator and gates should not depend on the cockpit UI directly.
  They emit operational view effects here; the current implementation stores
  those effects in the cockpit's on-box cache/stores.
  """

  alias SymphonyElixir.Cockpit.{BoardCache, EvidenceStore, RunSummaryStore}

  @spec invalidate_board() :: :ok
  def invalidate_board, do: BoardCache.invalidate()

  @spec put_run_summary(String.t(), String.t()) :: :ok
  def put_run_summary(issue_id, markdown)
      when is_binary(issue_id) and is_binary(markdown) do
    RunSummaryStore.put(issue_id, markdown)
  end

  @spec read_run_summary(String.t()) :: String.t() | nil
  def read_run_summary(issue_id) when is_binary(issue_id) do
    RunSummaryStore.read(issue_id)
  end

  @spec delete_run_summary(String.t()) :: :ok
  def delete_run_summary(issue_id) when is_binary(issue_id) do
    RunSummaryStore.delete(issue_id)
  end

  @spec publish_evidence(String.t(), Path.t()) :: :ok
  def publish_evidence(issue_id, src_dir) when is_binary(issue_id) do
    EvidenceStore.publish(issue_id, src_dir)
  end

  @spec read_evidence(String.t()) :: %{required(String.t()) => term()}
  def read_evidence(issue_id) when is_binary(issue_id) do
    EvidenceStore.read(issue_id)
  end

  @spec delete_evidence(String.t()) :: :ok
  def delete_evidence(issue_id) when is_binary(issue_id) do
    EvidenceStore.delete(issue_id)
  end
end
