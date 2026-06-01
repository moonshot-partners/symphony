defmodule SymphonyElixir.Linear.FetchCache do
  @moduledoc """
  Short-TTL read cache for the Linear poll fetches the orchestrator runs
  every tick.

  Per tick the orchestrator scans several Linear state buckets — dispatch
  candidates, completed-for-merge, promote-to-staging — and each scan was a
  separate GraphQL request. The request count therefore scaled with poll
  frequency and pinned the account against Linear's 2500 requests/hour cap
  (complexity was never the binding limit). Memoizing each scan for a few
  seconds collapses several ticks' worth of identical requests into one,
  cutting the request rate by roughly the TTL-to-poll-interval ratio while
  only ever serving data at most one TTL stale.

  Both `{:ok, _}` and `{:error, _}` are cached: under a rate-limit storm the
  failing scan then retries at most once per TTL instead of every tick,
  which is what lets Linear's rolling window drain and the budget recover.

  The TTL comes from the `:linear_fetch_cache_ttl_ms` app env (default 20s);
  the suite sets it to 0 so cached I/O never leaks across tests.
  """
  use GenServer

  @table __MODULE__
  @default_ttl_ms 20_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Return `fun.()`, memoized under `key` for `ttl_ms`. A non-positive
  `ttl_ms` bypasses the cache and always evaluates `fun`.

  Options: `:ttl_ms` (defaults to the `:linear_fetch_cache_ttl_ms` app env),
  `:now_ms` (defaults to the monotonic clock; injectable for tests).
  """
  @spec fetch(term(), (-> result), keyword()) :: result when result: var
  def fetch(key, fun, opts \\ []) when is_function(fun, 0) do
    ttl = Keyword.get(opts, :ttl_ms, default_ttl_ms())
    now = Keyword.get(opts, :now_ms, now_ms())

    if ttl > 0 do
      memoize(key, fun, ttl, now)
    else
      fun.()
    end
  end

  defp memoize(key, fun, ttl, now) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        value = fun.()
        :ets.insert(@table, {key, value, now + ttl})
        value
    end
  end

  defp default_ttl_ms,
    do: Application.get_env(:symphony_elixir, :linear_fetch_cache_ttl_ms, @default_ttl_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
