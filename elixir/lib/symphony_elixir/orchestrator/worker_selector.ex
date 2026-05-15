defmodule SymphonyElixir.Orchestrator.WorkerSelector do
  @moduledoc """
  Picks an SSH worker host for a new dispatch and reports host-level
  capacity.

  Extracted from `SymphonyElixir.Orchestrator` (CP9): the only orchestrator
  coupling is the `%State{running: ...}` map (read-only). No GenServer
  callbacks, no mutation.

  Behaviour preserved byte-for-byte from the in-orchestrator helpers
  `select_worker_host/2`, `worker_slots_available?/1`, `worker_slots_available?/2`.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.State

  @spec select(State.t(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded(state, available_hosts)
        end
    end
  end

  @spec slots_available?(State.t()) :: boolean()
  def slots_available?(%State{} = state) do
    select(state, nil) != :no_worker_capacity
  end

  @spec slots_available?(State.t(), String.t() | nil) :: boolean()
  def slots_available?(%State{} = state, preferred_worker_host) do
    select(state, preferred_worker_host) != :no_worker_capacity
  end

  defp preferred_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_host_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end
end
