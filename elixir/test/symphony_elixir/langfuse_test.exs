defmodule SymphonyElixir.LangfuseTest do
  # async: false — mutates LANGFUSE_* env and the injectable fetcher app config.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Langfuse

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :langfuse_trace_fetcher)
      Enum.each(
        ~w(LANGFUSE_HOST LANGFUSE_BASE_URL LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_SECRET),
        &System.delete_env/1
      )
    end)

    :ok
  end

  defp put_config do
    System.put_env("LANGFUSE_HOST", "https://lf.example.com/")
    System.put_env("LANGFUSE_PUBLIC_KEY", "pk")
    System.put_env("LANGFUSE_SECRET_KEY", "sk")
  end

  test "builds the trace url from a matched trace's htmlPath" do
    put_config()

    Application.put_env(:symphony_elixir, :langfuse_trace_fetcher, fn config, turn_id ->
      send(self(), {:fetched, config.host, turn_id})
      {:ok, %{"htmlPath" => "/project/p/traces/t"}}
    end)

    assert Langfuse.trace_url("sess-a-b-c-d-turn123") == "https://lf.example.com/project/p/traces/t"
    # host is trimmed of the trailing slash; turn id is the last session segment.
    assert_received {:fetched, "https://lf.example.com", "turn123"}
  end

  test "returns nil and never fetches when Langfuse is not configured" do
    Application.put_env(:symphony_elixir, :langfuse_trace_fetcher, fn _config, _turn ->
      flunk("must not fetch without config")
    end)

    assert Langfuse.trace_url("sess-a-b-c-d-turn123") == nil
  end

  test "returns nil for an unparseable or missing session id" do
    put_config()

    assert Langfuse.trace_url("short") == nil
    assert Langfuse.trace_url(nil) == nil
  end

  test "returns nil when no trace matches the turn id" do
    put_config()
    Application.put_env(:symphony_elixir, :langfuse_trace_fetcher, fn _config, _turn -> :error end)

    assert Langfuse.trace_url("sess-a-b-c-d-turn123") == nil
  end
end
