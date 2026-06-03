defmodule SymphonyElixir.Orchestrator.RuntimeStore do
  @moduledoc """
  Single boundary for resumable orchestrator runtime persistence.

  `Orchestrator.State` is the authoritative runtime source while the process
  is alive. This module owns the disk mirrors used to resume after restarts
  and to expose drain/status to deploy scripts, keeping those storage details
  out of the polling loop.
  """

  alias SymphonyElixir.Orchestrator.{StatusFile, WorkpadPersister, WorkpadStore}

  @type persisted_state :: %{
          required(:workpads) => %{String.t() => String.t()},
          required(:completed) => MapSet.t(String.t()),
          required(:pr_engagements) => map()
        }

  @spec load(Path.t(), Path.t()) :: persisted_state()
  def load(status_path, workpads_path) when is_binary(status_path) and is_binary(workpads_path) do
    runtime_state = StatusFile.load_runtime_state(status_path)

    %{
      workpads: WorkpadStore.load(workpads_path),
      completed: runtime_state.completed,
      pr_engagements: runtime_state.pr_engagements
    }
  end

  @spec save_workpads_async(Path.t(), %{String.t() => String.t()}) :: :ok
  def save_workpads_async(workpads_path, workpads)
      when is_binary(workpads_path) and is_map(workpads) do
    WorkpadPersister.save_async(workpads_path, workpads)
  end

  @spec drain_requested?(Path.t()) :: boolean()
  def drain_requested?(drain_flag_path) when is_binary(drain_flag_path) do
    StatusFile.drain_requested?(drain_flag_path)
  end

  @spec save_status(Path.t(), %{
          required(:running) => [String.t()],
          required(:drain) => boolean(),
          optional(:completed) => MapSet.t(String.t()),
          optional(:pr_engagements) => map()
        }) :: :ok
  def save_status(status_path, status) when is_binary(status_path) and is_map(status) do
    StatusFile.save(status_path, status)
  end
end
