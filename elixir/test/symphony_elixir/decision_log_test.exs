defmodule SymphonyElixir.DecisionLogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.DecisionLog

  setup do
    tmp = Path.join(System.tmp_dir!(), "decision_log_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    on_exit(fn -> System.delete_env("SYMPHONY_DECISION_LOG") end)
    {:ok, tmp: tmp}
  end

  describe "emit/3" do
    test "appends one JSON envelope per call", %{tmp: tmp} do
      path = Path.join(tmp, "decisions.jsonl")
      assert :ok = DecisionLog.emit("evt.one", %{a: 1}, path: path)
      assert :ok = DecisionLog.emit("evt.two", %{b: 2}, path: path)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
      first = Jason.decode!(Enum.at(lines, 0))
      assert first["event"] == "evt.one"
      assert first["payload"] == %{"a" => 1}
      second = Jason.decode!(Enum.at(lines, 1))
      assert second["event"] == "evt.two"
      assert second["payload"] == %{"b" => 2}
    end

    test "envelope includes ISO8601 ts", %{tmp: tmp} do
      path = Path.join(tmp, "decisions.jsonl")
      :ok = DecisionLog.emit("evt.x", %{}, path: path)
      [line] = path |> File.read!() |> String.split("\n", trim: true)
      ts = Jason.decode!(line)["ts"]
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(ts)
    end

    test "creates parent dir if missing", %{tmp: tmp} do
      nested = Path.join([tmp, "deep", "nested", "decisions.jsonl"])
      :ok = DecisionLog.emit("evt.create", %{}, path: nested)
      assert File.exists?(nested)
    end

    test "no-ops when SYMPHONY_DECISION_LOG=0", %{tmp: tmp} do
      System.put_env("SYMPHONY_DECISION_LOG", "0")
      path = Path.join(tmp, "decisions.jsonl")
      assert :ok = DecisionLog.emit("evt.gated", %{a: 1}, path: path)
      refute File.exists?(path)
    end

    test "default-on when env unset", %{tmp: tmp} do
      System.delete_env("SYMPHONY_DECISION_LOG")
      path = Path.join(tmp, "decisions.jsonl")
      assert :ok = DecisionLog.emit("evt.default", %{a: 1}, path: path)
      assert File.exists?(path)
    end

    test "swallows write errors and returns :ok", %{tmp: tmp} do
      # Point at a path inside a regular file (cannot be a directory) — mkdir_p will fail.
      sentinel = Path.join(tmp, "sentinel")
      File.write!(sentinel, "x")
      bad_path = Path.join(sentinel, "decisions.jsonl")
      assert :ok = DecisionLog.emit("evt.bad", %{}, path: bad_path)
    end

    test "non-encodable payload is logged as inspect fallback", %{tmp: tmp} do
      path = Path.join(tmp, "decisions.jsonl")
      # PIDs are not Jason-encodable; expect graceful fallback (no crash, file written).
      assert :ok = DecisionLog.emit("evt.unencodable", %{pid: self()}, path: path)
      assert File.exists?(path)
      [line] = path |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)
      assert decoded["event"] == "evt.unencodable"
      # Payload survives as a stringified inspect of the original map.
      assert is_binary(decoded["payload"])
      assert decoded["payload"] =~ "pid"
    end

    test "exercises default path arity-2 head" do
      # We can't actually write to /opt/symphony/state in tests, but the call
      # must not crash and must return :ok (error swallowed).
      assert :ok = DecisionLog.emit("evt.default_path", %{})
    end
  end

  describe "enabled?/0" do
    test "true when env unset (default ON for debugging)" do
      System.delete_env("SYMPHONY_DECISION_LOG")
      assert DecisionLog.enabled?() == true
    end

    test "true when SYMPHONY_DECISION_LOG=1" do
      System.put_env("SYMPHONY_DECISION_LOG", "1")
      assert DecisionLog.enabled?() == true
    end

    test "false when SYMPHONY_DECISION_LOG=0" do
      System.put_env("SYMPHONY_DECISION_LOG", "0")
      assert DecisionLog.enabled?() == false
    end

    test "true for arbitrary truthy strings (only '0' disables)" do
      System.put_env("SYMPHONY_DECISION_LOG", "yes")
      assert DecisionLog.enabled?() == true
    end
  end
end
