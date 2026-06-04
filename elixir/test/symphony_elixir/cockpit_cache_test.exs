defmodule SymphonyElixirWeb.CockpitCacheTest do
  use ExUnit.Case, async: false

  alias SymphonyElixirWeb.CockpitCache

  # CockpitCache is started by the application supervision tree, so tests drive
  # the running instance: inject deterministic counting builders, force the real
  # background-refresh cast, then flush it with :sys.get_state (no sleeps, no
  # real clock).
  setup do
    cache = Process.whereis(CockpitCache)
    assert is_pid(cache)

    {:ok, board_calls} = Agent.start_link(fn -> 0 end)

    Application.put_env(:symphony_elixir, :cockpit_board_builder, fn ->
      n = Agent.get_and_update(board_calls, &{&1 + 1, &1 + 1})
      %{states: %{}, tickets: [], build: n}
    end)

    Application.put_env(:symphony_elixir, :cockpit_live_builder, fn ->
      %{available: true, agents: [], retrying: [], polling: nil}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :cockpit_board_builder)
      Application.delete_env(:symphony_elixir, :cockpit_live_builder)
      Application.delete_env(:symphony_elixir, :cockpit_cache_fresh_ms)
    end)

    %{cache: cache, board_calls: board_calls}
  end

  defp force_refresh(cache, key) do
    GenServer.cast(cache, {:refresh, key})
    :sys.get_state(cache)
  end

  test "serves the cached payload and reuses it within the freshness window", %{
    cache: cache,
    board_calls: board_calls
  } do
    Application.put_env(:symphony_elixir, :cockpit_cache_fresh_ms, 60_000)
    force_refresh(cache, :board)
    builds = Agent.get(board_calls, & &1)

    first = CockpitCache.board()
    second = CockpitCache.board()

    # Both reads are within the window, so they reuse the same build.
    assert first.build == second.build
    assert Agent.get(board_calls, & &1) == builds
  end

  test "a stale read serves the cached value and rebuilds in the background", %{
    cache: cache,
    board_calls: board_calls
  } do
    Application.put_env(:symphony_elixir, :cockpit_cache_fresh_ms, 0)
    force_refresh(cache, :board)

    stale = CockpitCache.board()
    # The read returns immediately from cache and schedules a background refresh.
    assert is_integer(stale.build)

    :sys.get_state(cache)
    refreshed = CockpitCache.board()

    assert refreshed.build > stale.build
    assert Agent.get(board_calls, & &1) > stale.build
  end

  test "live payload is served from the cache", %{cache: cache} do
    Application.put_env(:symphony_elixir, :cockpit_cache_fresh_ms, 60_000)
    force_refresh(cache, :live)

    payload = CockpitCache.live()

    assert payload.available == true
    assert payload.agents == []
  end
end
