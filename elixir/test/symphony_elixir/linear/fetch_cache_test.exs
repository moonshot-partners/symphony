defmodule SymphonyElixir.Linear.FetchCacheTest do
  # async: false — the cache is a supervised singleton with one shared ETS
  # table; clearing it in setup keeps these cases isolated from each other.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.FetchCache

  setup do
    :ets.delete_all_objects(FetchCache)
    :ok
  end

  defp counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fun = fn ->
      n = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      {:ok, n}
    end

    {fun, fn -> Agent.get(agent, & &1) end}
  end

  test "first call misses and evaluates fun; a call within the TTL is a hit" do
    {fun, calls} = counter()

    assert {:ok, 1} = FetchCache.fetch(:k, fun, ttl_ms: 100, now_ms: 0)
    assert {:ok, 1} = FetchCache.fetch(:k, fun, ttl_ms: 100, now_ms: 99)
    assert calls.() == 1
  end

  test "a call at or past expiry re-evaluates fun" do
    {fun, calls} = counter()

    assert {:ok, 1} = FetchCache.fetch(:k, fun, ttl_ms: 100, now_ms: 0)
    # expires_at (100) is not strictly greater than now (100) -> miss
    assert {:ok, 2} = FetchCache.fetch(:k, fun, ttl_ms: 100, now_ms: 100)
    assert calls.() == 2
  end

  test "distinct keys are cached independently" do
    {fun, calls} = counter()

    assert {:ok, 1} = FetchCache.fetch({:by_states, ["A"]}, fun, ttl_ms: 100, now_ms: 0)
    assert {:ok, 2} = FetchCache.fetch({:by_states, ["B"]}, fun, ttl_ms: 100, now_ms: 0)
    assert {:ok, 1} = FetchCache.fetch({:by_states, ["A"]}, fun, ttl_ms: 100, now_ms: 10)
    assert calls.() == 2
  end

  test "error results are cached too, so a storm retries at most once per TTL" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    fun = fn -> {:error, Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)} end

    assert {:error, 1} = FetchCache.fetch(:k, fun, ttl_ms: 100, now_ms: 0)
    assert {:error, 1} = FetchCache.fetch(:k, fun, ttl_ms: 100, now_ms: 50)
    assert Agent.get(agent, & &1) == 1
  end

  test "a non-positive ttl bypasses the cache and always evaluates fun" do
    {fun, calls} = counter()

    assert {:ok, 1} = FetchCache.fetch(:k, fun, ttl_ms: 0, now_ms: 0)
    assert {:ok, 2} = FetchCache.fetch(:k, fun, ttl_ms: 0, now_ms: 0)
    assert calls.() == 2
  end

  test "with no opts it reads the suite default ttl (0) and the monotonic clock" do
    {fun, calls} = counter()

    # test_helper pins :linear_fetch_cache_ttl_ms to 0 -> default path bypasses.
    assert {:ok, 1} = FetchCache.fetch(:k, fun)
    assert {:ok, 2} = FetchCache.fetch(:k, fun)
    assert calls.() == 2
  end

  test "a positive default ttl memoizes through the default path" do
    {fun, calls} = counter()
    prev = Application.get_env(:symphony_elixir, :linear_fetch_cache_ttl_ms)
    Application.put_env(:symphony_elixir, :linear_fetch_cache_ttl_ms, 60_000)
    on_exit(fn -> Application.put_env(:symphony_elixir, :linear_fetch_cache_ttl_ms, prev) end)

    # No :now_ms -> uses the monotonic clock; two back-to-back calls fall well
    # within the 60s TTL, so the second is a hit deterministically.
    assert {:ok, 1} = FetchCache.fetch(:k, fun)
    assert {:ok, 1} = FetchCache.fetch(:k, fun)
    assert calls.() == 1
  end
end
