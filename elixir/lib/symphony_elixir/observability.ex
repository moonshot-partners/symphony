defmodule SymphonyElixir.Observability do
  @moduledoc """
  Boot-time diagnostic for OpenTelemetry env propagation.

  The Python shim and the `claude` CLI it spawns rely on parent-process env
  inheritance for OTel configuration. When users run Symphony without sourcing
  `~/.symphony/launch.sh`, the OTel env never enters the BEAM and telemetry
  silently disappears. This module reports the status at boot so the gap is
  visible in logs.
  """

  require Logger

  @required_when_enabled ~w(
    OTEL_EXPORTER_OTLP_ENDPOINT
    OTEL_SERVICE_NAME
    OTEL_TRACES_EXPORTER
  )

  @type status ::
          {:disabled, []}
          | {:partial, [String.t()]}
          | {:ok, %{endpoint: String.t(), service_name: String.t(), headers_present: boolean()}}

  @spec report_status() :: status()
  def report_status do
    headers = System.get_env("OTEL_EXPORTER_OTLP_HEADERS")
    endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    service_name = System.get_env("OTEL_SERVICE_NAME")
    traces_exporter = System.get_env("OTEL_TRACES_EXPORTER")

    case {present?(headers), missing_required()} do
      {false, _} ->
        Logger.info("Observability: telemetry disabled (no OTel env detected; source ~/.symphony/launch.sh to enable)")
        {:disabled, []}

      {true, []} ->
        Logger.info("Observability: telemetry configured (service=#{service_name} endpoint=#{endpoint} traces_exporter=#{traces_exporter})")

        {:ok,
         %{
           endpoint: endpoint,
           service_name: service_name,
           headers_present: true
         }}

      {true, missing} ->
        Logger.warning("Observability: telemetry partially configured (OTEL_EXPORTER_OTLP_HEADERS set, missing #{Enum.join(missing, ", ")})")

        {:partial, missing}
    end
  end

  defp missing_required do
    Enum.filter(@required_when_enabled, fn key -> not present?(System.get_env(key)) end)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true
end
