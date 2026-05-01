defmodule SymphonyElixirWeb.BoardCacheTest do
  use ExUnit.Case, async: false

  alias SymphonyElixirWeb.BoardCache

  setup do
    name = :"board_cache_#{System.unique_integer([:positive])}"
    {:ok, pid} = BoardCache.start_link(name: name, ttl_ms: 50)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{cache: name}
  end

  test "first call computes payload and caches it", %{cache: cache} do
    counter = :counters.new(1, [])

    builder = fn ->
      :counters.add(counter, 1, 1)
      %{generated_at: "t", columns: []}
    end

    assert %{columns: []} = BoardCache.fetch(cache, builder)
    assert :counters.get(counter, 1) == 1
  end

  test "fresh hit returns cached payload without calling builder", %{cache: cache} do
    counter = :counters.new(1, [])

    builder = fn ->
      :counters.add(counter, 1, 1)
      %{generated_at: "t", columns: [%{key: "todo"}]}
    end

    BoardCache.fetch(cache, builder)
    BoardCache.fetch(cache, builder)
    BoardCache.fetch(cache, builder)

    assert :counters.get(counter, 1) == 1
  end

  test "stale hit returns cached payload immediately and refreshes async", %{cache: cache} do
    counter = :counters.new(1, [])
    parent = self()

    builder = fn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(parent, {:built, n})
      %{generated_at: "t#{n}", columns: []}
    end

    assert %{generated_at: "t0"} = BoardCache.fetch(cache, builder)
    assert_receive {:built, 0}, 200

    Process.sleep(80)

    assert %{generated_at: "t0"} = BoardCache.fetch(cache, builder)

    assert_receive {:built, 1}, 500

    Process.sleep(50)
    assert %{generated_at: "t1"} = BoardCache.fetch(cache, builder)
  end

  test "concurrent stale hits trigger only one refresh", %{cache: cache} do
    counter = :counters.new(1, [])

    builder = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(30)
      %{generated_at: "t", columns: []}
    end

    BoardCache.fetch(cache, builder)
    Process.sleep(80)

    Enum.map(1..10, fn _ ->
      Task.async(fn -> BoardCache.fetch(cache, builder) end)
    end)
    |> Enum.each(&Task.await/1)

    Process.sleep(80)
    assert :counters.get(counter, 1) <= 2
  end

end
