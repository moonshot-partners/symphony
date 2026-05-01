defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @spec healthz(Conn.t(), map()) :: Conn.t()
  def healthz(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec board(Conn.t(), map()) :: Conn.t()
  def board(conn, _params) do
    json(conn, Presenter.board_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec stream(Conn.t(), map()) :: Conn.t()
  def stream(conn, _params) do
    :ok = ObservabilityPubSub.subscribe()

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("x-accel-buffering", "no")
    |> Conn.send_chunked(200)
    |> sse_initial_chunk()
    |> sse_loop()
  end

  defp sse_initial_chunk(conn) do
    case Conn.chunk(conn, ":ok\n\n") do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  # Firefox aborts the fetch ReadableStream with `TypeError: Error in input stream`
  # when SSE keepalives go above ~7.5s. Keep the heartbeat at 5s for compatibility.
  @sse_heartbeat_ms 5_000

  defp sse_loop(conn) do
    receive do
      :observability_updated ->
        case Conn.chunk(conn, "event: board_updated\ndata: {}\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _closed} -> conn
        end
    after
      @sse_heartbeat_ms ->
        case Conn.chunk(conn, ":heartbeat\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _closed} -> conn
        end
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
