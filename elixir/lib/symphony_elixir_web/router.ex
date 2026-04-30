defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's headless observability JSON API.
  """

  use Phoenix.Router

  scope "/", SymphonyElixirWeb do
    get("/healthz", ObservabilityApiController, :healthz)
    match(:*, "/healthz", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/board", ObservabilityApiController, :board)
    match(:*, "/api/v1/board", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/stream", ObservabilityApiController, :stream)
    match(:*, "/api/v1/stream", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
