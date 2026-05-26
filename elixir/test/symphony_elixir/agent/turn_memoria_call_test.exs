defmodule SymphonyElixir.Agent.AppServer.TurnMemoriaCallTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Agent.AppServer.Turn
  alias SymphonyElixir.DecisionLog

  setup do
    tmp = Path.join(System.tmp_dir!(), "turn_memoria_call_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "decisions.jsonl")

    prior_env = System.get_env("SYMPHONY_DECISION_LOG")
    prior_app = Application.get_env(:symphony_elixir, :decision_log_path)

    System.put_env("SYMPHONY_DECISION_LOG", "1")
    Application.put_env(:symphony_elixir, :decision_log_path, path)

    on_exit(fn ->
      File.rm_rf!(tmp)

      case prior_env do
        nil -> System.delete_env("SYMPHONY_DECISION_LOG")
        val -> System.put_env("SYMPHONY_DECISION_LOG", val)
      end

      case prior_app do
        nil -> Application.delete_env(:symphony_elixir, :decision_log_path)
        val -> Application.put_env(:symphony_elixir, :decision_log_path, val)
      end
    end)

    {:ok, decisions_path: path}
  end

  # Helper: open a port that writes the given JSON-RPC lines (each followed by
  # a newline) then exits. The port uses `printf` to emit lines atomically.
  defp fake_port(lines) do
    # Use `sh -c printf` to emit each line then exit cleanly.
    joined = Enum.map_join(lines, "\n", & &1)

    Port.open(
      {:spawn_executable, System.find_executable("sh")},
      [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: ["-c", "printf '#{String.replace(joined, "'", "'\\''")}\\n'"]
      ]
    )
  end

  describe "notifications/memoria_call routing in turn.ex" do
    test "persists memoria.call to decisions.jsonl when notification arrives", %{
      decisions_path: path
    } do
      params = %{
        "query" => "grading policy",
        "tool" => "search_knowledge",
        "result_status" => "ok",
        "source_ids" => ["doc-1"],
        "filtered_count" => 1
      }

      memoria_notification =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/memoria_call",
          "params" => params
        })

      turn_completed =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "turn/completed",
          "params" => %{}
        })

      port = fake_port([memoria_notification, turn_completed])

      on_message = fn _msg -> :ok end
      noop_executor = fn _tool_name, _input -> {:ok, "ok"} end

      result = Turn.await_completion(port, on_message, noop_executor, true)

      assert result == {:ok, :turn_completed}

      assert File.exists?(path),
             "decisions.jsonl was not created — notifications/memoria_call case clause missing"

      [line] = path |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)
      assert decoded["event"] == "memoria.call"
      assert decoded["payload"]["query"] == "grading policy"
      assert decoded["payload"]["tool"] == "search_knowledge"
      assert decoded["payload"]["result_status"] == "ok"
      assert decoded["payload"]["filtered_count"] == 1
    end

    test "also emits :notification on_message event (observability preserved)", %{
      decisions_path: _path
    } do
      memoria_notification =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/memoria_call",
          "params" => %{"query" => "test", "tool" => "search_knowledge", "result_status" => "ok"}
        })

      turn_completed =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "turn/completed",
          "params" => %{}
        })

      port = fake_port([memoria_notification, turn_completed])

      events = :ets.new(:events, [:bag, :public])
      on_message = fn msg -> :ets.insert(events, {:event, msg.event}) end
      noop_executor = fn _tool_name, _input -> {:ok, "ok"} end

      result = Turn.await_completion(port, on_message, noop_executor, true)

      assert result == {:ok, :turn_completed}

      all_events = :ets.lookup(events, :event) |> Enum.map(fn {:event, e} -> e end)

      assert :notification in all_events,
             "Expected :notification event in on_message callback, got: #{inspect(all_events)}"
    end

    test "non-memoria notifications are unaffected", %{decisions_path: path} do
      other_notification =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/some_other_event",
          "params" => %{"data" => "irrelevant"}
        })

      turn_completed =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "turn/completed",
          "params" => %{}
        })

      port = fake_port([other_notification, turn_completed])

      on_message = fn _msg -> :ok end
      noop_executor = fn _tool_name, _input -> {:ok, "ok"} end

      result = Turn.await_completion(port, on_message, noop_executor, true)

      assert result == {:ok, :turn_completed}

      # No memoria.call entry for non-memoria notification
      refute File.exists?(path),
             "decisions.jsonl should NOT be created for non-memoria notifications"
    end
  end

  describe "DecisionLog.emit/2 with memoria.call event (unit)" do
    test "appends correct envelope to jsonl", %{decisions_path: path} do
      params = %{
        "query" => "fee schedule",
        "tool" => "get_article",
        "result_status" => "no_results",
        "source_ids" => [],
        "filtered_count" => 0
      }

      assert :ok = DecisionLog.emit("memoria.call", params, path: path)

      [line] = path |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)
      assert decoded["event"] == "memoria.call"
      assert decoded["payload"]["result_status"] == "no_results"
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(decoded["ts"])
    end
  end
end
