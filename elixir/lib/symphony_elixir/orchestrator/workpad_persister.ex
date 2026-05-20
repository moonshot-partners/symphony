defmodule SymphonyElixir.Orchestrator.WorkpadPersister do
  @moduledoc """
  Serializes workpad-map disk writes off the Orchestrator process.

  `WorkpadStore.save/2` is a synchronous `File.write`. Calling it from
  inside the Orchestrator GenServer blocks all message processing on disk
  I/O — on a slow or full filesystem this stalls the poll cycle.

  This GenServer owns the write. The Orchestrator `cast`s the latest
  workpad map and returns immediately, never blocking on disk. Casts are
  processed in arrival order, so the last map the Orchestrator handed
  over is the last one written — independent `Task`s racing on the same
  path could reorder and leave a stale recovery file, which is exactly
  the duplicate-workpad bug `WorkpadStore` exists to prevent.

  A failed write is logged, not raised: a crash here would lose nothing
  durable (the Orchestrator keeps the authoritative in-memory map) and
  the next turn's cast re-attempts the write.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Orchestrator.WorkpadStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  Hand the latest workpad map to the persister for an ordered, off-process
  disk write. Returns immediately — the caller never blocks on I/O.
  """
  @spec save_async(Path.t(), %{String.t() => String.t()}, GenServer.server()) :: :ok
  def save_async(path, workpads, server \\ __MODULE__)
      when is_binary(path) and is_map(workpads) do
    GenServer.cast(server, {:save, path, workpads})
  end

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_cast({:save, path, workpads}, state) do
    case WorkpadStore.save(path, workpads) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "WorkpadStore.save failed (reason=#{inspect(reason)}); " <>
            "continuing with in-memory workpads only"
        )
    end

    {:noreply, state}
  end
end
