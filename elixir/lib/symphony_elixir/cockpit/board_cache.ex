defmodule SymphonyElixir.Cockpit.BoardCache do
  @moduledoc """
  Short-TTL cache for the assembled board. The board build does external reads
  (Linear, GitHub) whose budgets are shared with the live agent; this bounds
  them to at most one build per TTL regardless of how often the cockpit polls.
  Calls serialize through the GenServer, so a concurrent burst triggers one
  build, not many. When the process is not running (tests), the build runs
  inline uncached.
  """

  use GenServer

  @ttl_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Return the cached board, or run build_fun and cache it when stale."
  @spec board((-> map())) :: map()
  def board(build_fun) when is_function(build_fun, 0) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:board, build_fun}, 30_000),
      else: build_fun.()
  end

  @impl true
  def init(opts) do
    {:ok, %{board: nil, at: 0, ttl: Keyword.get(opts, :ttl_ms, @ttl_ms)}}
  end

  @impl true
  def handle_call({:board, build_fun}, _from, %{board: cached, at: at, ttl: ttl} = state) do
    now = System.monotonic_time(:millisecond)

    if cached != nil and now - at < ttl do
      {:reply, cached, state}
    else
      board = build_fun.()
      {:reply, board, %{state | board: board, at: now}}
    end
  end
end
