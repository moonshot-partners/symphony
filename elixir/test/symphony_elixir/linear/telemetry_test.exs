defmodule SymphonyElixir.Linear.TelemetryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Telemetry

  setup do
    Telemetry.reset()
    :ok
  end

  describe "timeout_error?/1" do
    test "classifies bare {:error, :timeout}" do
      assert Telemetry.timeout_error?({:error, :timeout})
    end

    test "classifies struct with reason: :timeout" do
      assert Telemetry.timeout_error?({:error, %{reason: :timeout}})
    end

    test "classifies nested {:linear_api_request, :timeout}" do
      assert Telemetry.timeout_error?({:error, {:linear_api_request, :timeout}})
    end

    test "classifies nested {:linear_api_request, %{reason: :timeout}}" do
      assert Telemetry.timeout_error?({:error, {:linear_api_request, %{reason: :timeout, source: :req}}})
    end

    test "rejects non-timeout errors" do
      refute Telemetry.timeout_error?({:error, :missing_linear_api_token})
      refute Telemetry.timeout_error?({:error, {:linear_api_status, 500}})
      refute Telemetry.timeout_error?({:error, %{reason: :closed}})
      refute Telemetry.timeout_error?({:ok, %{}})
    end
  end

  describe "record_timeout/0 and count/0" do
    test "starts at zero" do
      assert Telemetry.count() == 0
    end

    test "increments by one per call" do
      Telemetry.record_timeout()
      Telemetry.record_timeout()
      Telemetry.record_timeout()
      assert Telemetry.count() == 3
    end

    test "reset/0 returns count to zero" do
      Telemetry.record_timeout()
      Telemetry.record_timeout()
      assert Telemetry.count() == 2
      Telemetry.reset()
      assert Telemetry.count() == 0
    end
  end

  describe "maybe_record_timeout/1" do
    test "increments and returns the result unchanged on timeout error" do
      result = {:error, :timeout}
      assert ^result = Telemetry.maybe_record_timeout(result)
      assert Telemetry.count() == 1
    end

    test "does not increment on non-timeout error" do
      result = {:error, :missing_linear_api_token}
      assert ^result = Telemetry.maybe_record_timeout(result)
      assert Telemetry.count() == 0
    end

    test "does not increment on success" do
      result = {:ok, %{}}
      assert ^result = Telemetry.maybe_record_timeout(result)
      assert Telemetry.count() == 0
    end
  end
end
