defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Application.put_env(:logger, :truncate, 32_768)
    :ok = SymphonyElixir.LogFile.configure()

    children =
      [
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.Orchestrator.WorkpadPersister,
        SymphonyElixir.Orchestrator
      ] ++ cockpit_children()

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state), do: :ok

  # Read-only cockpit HTTP API. Inert unless SYMPHONY_COCKPIT_API_PORT is set,
  # so the orchestrator boots identically wherever it is not opted in. The
  # one_for_one strategy means an API crash never restarts the agent.
  @doc false
  @spec cockpit_children() :: [{module(), keyword()}]
  def cockpit_children do
    case System.get_env("SYMPHONY_COCKPIT_API_PORT") do
      port when is_binary(port) and port != "" ->
        [{Bandit, plug: SymphonyElixir.Cockpit.Api, scheme: :http, port: String.to_integer(port)}]

      _ ->
        []
    end
  end
end
