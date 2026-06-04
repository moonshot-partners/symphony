defmodule SymphonyElixir.Langfuse do
  @moduledoc """
  Resolves the Langfuse trace URL for an agent session, best-effort.

  A session id encodes the turn id as its last `-`-delimited segment, and the
  Langfuse trace carries that turn id under `metadata.attributes["turn.id"]`. With
  no Langfuse credentials configured (`LANGFUSE_*`), `trace_url/1` returns nil and
  never makes a request. The HTTP fetch is overridable via
  `:langfuse_trace_fetcher` for deterministic tests.
  """

  @doc """
  Returns the Langfuse trace URL for a session id, or nil when it cannot be
  resolved (no config, unparseable session, no matching trace, request failure).
  """
  @spec trace_url(String.t() | nil) :: String.t() | nil
  def trace_url(session_id) do
    with {:ok, config} <- config(),
         {:ok, turn_id} <- session_turn_id(session_id),
         {:ok, trace} <- fetch_trace(config, turn_id) do
      build_url(config.host, trace)
    else
      _ -> nil
    end
  end

  defp config do
    host = System.get_env("LANGFUSE_HOST") || System.get_env("LANGFUSE_BASE_URL")
    public_key = System.get_env("LANGFUSE_PUBLIC_KEY")
    secret_key = System.get_env("LANGFUSE_SECRET_KEY") || System.get_env("LANGFUSE_SECRET")

    if present?(host) and present?(public_key) and present?(secret_key) do
      {:ok, %{host: String.trim_trailing(host, "/"), public_key: public_key, secret_key: secret_key}}
    else
      :error
    end
  end

  defp session_turn_id(session_id) when is_binary(session_id) do
    case String.split(session_id, "-", parts: 6) do
      [_, _, _, _, _, turn_id] when byte_size(turn_id) > 0 -> {:ok, turn_id}
      _ -> :error
    end
  end

  defp session_turn_id(_session_id), do: :error

  defp fetch_trace(config, turn_id) do
    fetcher = Application.get_env(:symphony_elixir, :langfuse_trace_fetcher, &default_fetch_trace/2)
    fetcher.(config, turn_id)
  end

  defp default_fetch_trace(%{host: host, public_key: public_key, secret_key: secret_key}, turn_id) do
    auth = Base.encode64("#{public_key}:#{secret_key}")

    case Req.get("#{host}/api/public/traces",
           params: [limit: 50],
           headers: [{"authorization", "Basic #{auth}"}],
           receive_timeout: 1_500
         ) do
      {:ok, %{status: status, body: %{"data" => traces}}} when status in 200..299 ->
        traces
        |> Enum.find(&trace_matches_turn_id?(&1, turn_id))
        |> case do
          nil -> :error
          trace -> {:ok, trace}
        end

      _ ->
        :error
    end
  end

  defp trace_matches_turn_id?(%{"metadata" => %{"attributes" => attributes}}, turn_id)
       when is_map(attributes) do
    Map.get(attributes, "turn.id") == turn_id
  end

  defp trace_matches_turn_id?(_trace, _turn_id), do: false

  defp build_url(host, %{"htmlPath" => html_path}) when is_binary(html_path) do
    host <> html_path
  end

  defp build_url(_host, %{"id" => id, "projectId" => project_id})
       when is_binary(id) and is_binary(project_id) do
    "https://cloud.langfuse.com/project/#{project_id}/traces/#{id}"
  end

  defp build_url(_host, _trace), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
