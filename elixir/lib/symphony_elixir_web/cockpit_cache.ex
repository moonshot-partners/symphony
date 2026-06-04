defmodule SymphonyElixirWeb.CockpitCache do
  @moduledoc """
  Stale-while-revalidate cache for the cockpit's board and live payloads.

  The dashboard polls `/board` (~1.5s) and `/live` (~2s). Built per request,
  each poll did a Linear pipeline fetch (board) and an orchestrator snapshot
  call (live) that queues behind the orchestrator's poll/reconcile cycle. That
  made the first open wait on a cold Linear round-trip plus a queued snapshot,
  and hit the shared Linear rate limit once per poll per open tab.

  This cache serves the last good payload from an ETS table (O(1), never blocks
  on Linear or the orchestrator). On a read it returns the cached value
  immediately and, if older than the freshness window, kicks off a background
  rebuild. It refreshes only when read, so an idle cockpit drives no Linear
  traffic. The cache is prewarmed once on boot so the first browser load is
  already warm.
  """
  use GenServer

  require Logger

  alias SymphonyElixirWeb.ObservabilityApiController

  @table :cockpit_cache
  @default_fresh_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Cached board payload, refreshing in the background when stale."
  @spec board() :: map()
  def board, do: get(:board)

  @doc "Cached live payload, refreshing in the background when stale."
  @spec live() :: map()
  def live, do: get(:live)

  defp get(key) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {payload, built_at} ->
        if now - built_at >= fresh_ms() do
          GenServer.cast(__MODULE__, {:refresh, key})
        end

        payload

      :miss ->
        # Cold cache (before the boot prewarm landed, or the cache is not
        # running, e.g. in a unit test that calls the controller directly):
        # build synchronously so the caller still gets a real payload.
        build(key)
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, payload, built_at}] -> {payload, built_at}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    # Prewarm both payloads so the first browser load reads a warm cache.
    GenServer.cast(self(), {:refresh, :board})
    GenServer.cast(self(), {:refresh, :live})
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:refresh, key}, state) do
    build(key)
    {:noreply, state}
  end

  defp build(key) do
    payload = builder(key).()
    store(key, payload)
    payload
  rescue
    error ->
      Logger.warning("cockpit cache build failed for #{key}: #{inspect(error)}")
      # Fall back to whatever is cached; if nothing, an empty shell so the
      # endpoint still answers with valid JSON rather than crashing.
      case lookup(key) do
        {payload, _built_at} -> payload
        :miss -> empty_payload(key)
      end
  end

  defp store(key, payload) do
    :ets.insert(@table, {key, payload, System.monotonic_time(:millisecond)})
    payload
  rescue
    ArgumentError -> payload
  end

  defp builder(:board) do
    Application.get_env(
      :symphony_elixir,
      :cockpit_board_builder,
      &ObservabilityApiController.build_board_payload/0
    )
  end

  defp builder(:live) do
    Application.get_env(
      :symphony_elixir,
      :cockpit_live_builder,
      &ObservabilityApiController.build_live_payload/0
    )
  end

  defp empty_payload(:board), do: %{states: %{}, tickets: []}
  defp empty_payload(:live), do: %{available: false, agents: [], retrying: [], polling: nil}

  defp fresh_ms do
    Application.get_env(:symphony_elixir, :cockpit_cache_fresh_ms, @default_fresh_ms)
  end
end
