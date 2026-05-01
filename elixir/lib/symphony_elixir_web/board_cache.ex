defmodule SymphonyElixirWeb.BoardCache do
  @moduledoc """
  Stale-while-revalidate cache for the `/api/v1/board` payload.

  The first call computes the payload synchronously and caches it. Subsequent
  calls within `ttl_ms` return the cached value with no recompute. Calls after
  the TTL window return the stale value immediately and trigger a single async
  refresh — concurrent stale hits coalesce so the underlying builder runs at
  most once at a time.

  Backed by an ETS table owned by the GenServer. Reads are lock-free.
  """

  use GenServer

  @default_ttl_ms 5_000

  @type payload :: map()
  @type builder :: (-> payload())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the cached payload, computing it via `builder` on a miss. Stale hits
  return the cached payload and kick off an async refresh.
  """
  @spec fetch(atom(), builder()) :: payload()
  def fetch(server \\ __MODULE__, builder) when is_atom(server) and is_function(builder, 0) do
    table = ets_table(server)
    now = System.monotonic_time(:millisecond)

    case ets_lookup(table) do
      :miss ->
        payload = builder.()
        store(table, payload, configured_ttl(server))
        payload

      {:hit, payload, cached_at, ttl_ms} ->
        if now - cached_at <= ttl_ms do
          payload
        else
          GenServer.cast(server, {:refresh, builder})
          payload
        end
    end
  end

  @doc """
  Clears the cache entry. Mostly used by tests.
  """
  @spec clear(atom()) :: :ok
  def clear(server \\ __MODULE__) when is_atom(server) do
    table = ets_table(server)

    try do
      :ets.delete(table, :payload)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @impl true
  def init(opts) do
    table = :ets.new(:"#{Keyword.get(opts, :name, __MODULE__)}_table", [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    state = %{
      table: table,
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      refreshing?: false
    }

    name = Keyword.get(opts, :name, __MODULE__)
    :persistent_term.put({__MODULE__, :table_for, name}, table)
    :persistent_term.put({__MODULE__, :ttl_for, name}, state.ttl_ms)

    {:ok, state}
  end

  @impl true
  def handle_cast({:refresh, builder}, state) do
    if state.refreshing? do
      {:noreply, state}
    else
      {:noreply, schedule_refresh(state, builder)}
    end
  end

  @impl true
  def handle_info({:refresh_done, payload}, %{table: table, ttl_ms: ttl_ms} = state) do
    store(table, payload, ttl_ms)
    {:noreply, %{state | refreshing?: false}}
  end

  @impl true
  def handle_info({:refresh_failed, _reason}, state) do
    {:noreply, %{state | refreshing?: false}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp schedule_refresh(state, builder) do
    parent = self()

    Task.start(fn ->
      try do
        payload = builder.()
        send(parent, {:refresh_done, payload})
      rescue
        e -> send(parent, {:refresh_failed, e})
      catch
        kind, reason -> send(parent, {:refresh_failed, {kind, reason}})
      end
    end)

    %{state | refreshing?: true}
  end

  defp ets_table(server) when is_atom(server) do
    case :persistent_term.get({__MODULE__, :table_for, server}, :undefined) do
      :undefined -> :"#{server}_table"
      table -> table
    end
  end

  defp configured_ttl(server) when is_atom(server) do
    :persistent_term.get({__MODULE__, :ttl_for, server}, @default_ttl_ms)
  end

  defp ets_lookup(table) do
    case :ets.lookup(table, :payload) do
      [{:payload, payload, cached_at, ttl_ms}] -> {:hit, payload, cached_at, ttl_ms}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(table, payload, ttl_ms) do
    :ets.insert(table, {:payload, payload, System.monotonic_time(:millisecond), ttl_ms})
  end
end
