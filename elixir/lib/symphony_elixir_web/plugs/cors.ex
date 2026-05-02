defmodule SymphonyElixirWeb.Plugs.CORS do
  @moduledoc """
  Minimal CORS plug for Symphony's observability JSON API.

  Allows the symphony-ui dev origin (default `http://localhost:3000`) to call
  `/api/v1/*` endpoints. Configurable via the `:cors_allowed_origins` endpoint
  config key.
  """

  import Plug.Conn

  @default_origins ["http://localhost:3000", "http://localhost:3100"]
  @allow_methods "GET, POST, OPTIONS"
  @allow_headers "content-type, accept, cache-control"

  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(%Plug.Conn{request_path: "/api/v1/" <> _} = conn, _opts) do
    handle(conn)
  end

  def call(conn, _opts), do: conn

  defp handle(conn) do
    case origin(conn) do
      nil -> conn
      origin -> apply_cors(conn, origin)
    end
  end

  defp apply_cors(conn, origin) do
    if allowed?(origin) do
      conn |> put_cors_headers(origin) |> maybe_short_circuit_preflight()
    else
      conn
    end
  end

  defp maybe_short_circuit_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end

  defp maybe_short_circuit_preflight(conn), do: conn

  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] -> origin
      [] -> nil
    end
  end

  defp allowed?(origin) do
    origin in allowed_origins()
  end

  defp allowed_origins do
    SymphonyElixirWeb.Endpoint.config(:cors_allowed_origins) || @default_origins
  end

  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-allow-headers", @allow_headers)
    |> put_resp_header("vary", "origin")
  end
end
