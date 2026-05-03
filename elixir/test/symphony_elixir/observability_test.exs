defmodule SymphonyElixir.ObservabilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Observability

  @otel_keys [
    "OTEL_EXPORTER_OTLP_HEADERS",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_SERVICE_NAME",
    "OTEL_TRACES_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "CLAUDE_CODE_ENABLE_TELEMETRY"
  ]

  setup do
    saved =
      Map.new(@otel_keys, fn key -> {key, System.get_env(key)} end)

    Enum.each(@otel_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@otel_keys, fn key ->
        case Map.get(saved, key) do
          nil -> System.delete_env(key)
          value -> System.put_env(key, value)
        end
      end)
    end)

    :ok
  end

  test "report_status returns :disabled when no OTel env is set" do
    log =
      capture_log(fn ->
        assert {:disabled, []} = Observability.report_status()
      end)

    assert log =~ "telemetry disabled"
  end

  test "report_status returns :partial when headers set but endpoint or exporter missing" do
    System.put_env("OTEL_EXPORTER_OTLP_HEADERS", "x-honeycomb-team=KEY")

    log =
      capture_log(fn ->
        assert {:partial, missing} = Observability.report_status()
        assert "OTEL_EXPORTER_OTLP_ENDPOINT" in missing
        assert "OTEL_SERVICE_NAME" in missing
        assert "OTEL_TRACES_EXPORTER" in missing
      end)

    assert log =~ "telemetry partially configured"
    assert log =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
  end

  test "report_status returns :ok when minimum required vars are present" do
    System.put_env("OTEL_EXPORTER_OTLP_HEADERS", "x-honeycomb-team=KEY")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://api.honeycomb.io")
    System.put_env("OTEL_SERVICE_NAME", "symphony")
    System.put_env("OTEL_TRACES_EXPORTER", "otlp")

    log =
      capture_log(fn ->
        assert {:ok, status} = Observability.report_status()
        assert status.endpoint == "https://api.honeycomb.io"
        assert status.service_name == "symphony"
        assert status.headers_present == true
      end)

    assert log =~ "telemetry configured"
    assert log =~ "symphony"
    refute log =~ "x-honeycomb-team=KEY",
           "headers value must never be logged"
  end
end
