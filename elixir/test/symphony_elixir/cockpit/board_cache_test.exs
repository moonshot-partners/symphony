defmodule SymphonyElixir.Cockpit.BoardCacheTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Cockpit.BoardCache

  test "serves cached board until invalidated" do
    start_supervised!({BoardCache, ttl_ms: 60_000})
    counter = :counters.new(1, [])

    build = fn ->
      :counters.add(counter, 1, 1)
      %{"build" => :counters.get(counter, 1)}
    end

    assert BoardCache.board(build) == %{"build" => 1}
    assert BoardCache.board(build) == %{"build" => 1}

    assert :ok = BoardCache.invalidate()
    assert BoardCache.board(build) == %{"build" => 2}
  end

  test "invalidate is a no-op when the cache process is absent" do
    refute Process.whereis(BoardCache)
    assert :ok = BoardCache.invalidate()
  end
end
