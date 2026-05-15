defmodule SymphonyElixir.Agent.AppServer.Transport do
  @moduledoc """
  JSON-RPC 2.0 transport layer for the Agent app-server: port spawn / stop,
  framed line I/O, and synchronous request/response with timeout.

  Extracted from `SymphonyElixir.Agent.AppServer` (CP A) — pure shell-out
  around Erlang `Port`, no GenServer, no session state. The session module
  composes these primitives.

  Behaviour preserved byte-for-byte from the in-AppServer helpers.
  """

  require Logger
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @docker_passthrough_env ~w[
    ANTHROPIC_API_KEY
    ANTHROPIC_OAUTH_TOKEN
    ANTHROPIC_BASE_URL
    CLAUDE_CODE_OAUTH_TOKEN
    LINEAR_API_KEY
    GH_TOKEN
    GITHUB_TOKEN
    SYMPHONY_WORKFLOW_FILE
  ]

  @spec start_port(Path.t(), String.t() | nil) :: {:ok, port()} | {:error, term()}
  def start_port(workspace, nil) do
    case Config.settings!().agent_runtime.docker_image do
      nil -> start_port_bash(workspace)
      image -> start_port_docker(workspace, image)
    end
  end

  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  @spec send_message(port(), map()) :: true
  def send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  @spec await_response(port(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().agent_runtime.read_timeout_ms, "")
  end

  @spec port_metadata(port(), String.t() | nil) :: map()
  def port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{agent_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  @spec shim_cwd(Path.t()) :: Path.t()
  def shim_cwd(host_path) do
    case Config.settings!().agent_runtime.docker_image do
      nil -> host_path
      # Workspace is mounted at /workspace inside the container.
      _image -> "/workspace"
    end
  end

  @spec log_non_json_stream_line(binary() | charlist(), String.t()) :: :ok
  def log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Agent #{stream_label} output: #{text}")
      else
        Logger.debug("Agent #{stream_label} output: #{text}")
      end
    end

    :ok
  end

  @spec protocol_message_candidate?(binary() | charlist()) :: boolean()
  def protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp start_port_bash(workspace) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(Config.settings!().agent_runtime.command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port_docker(workspace, image) do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      executable ->
        # CMD is baked into the image — no override needed here.
        args =
          ["run", "--rm", "-i"] ++
            docker_env_args() ++
            ["-v", "#{workspace}:/workspace", "-w", "/workspace", image]

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: Enum.map(args, &String.to_charlist/1),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp docker_env_args do
    Enum.flat_map(@docker_passthrough_env, fn var ->
      case System.get_env(var) do
        nil -> []
        val -> ["-e", "#{var}=#{val}"]
      end
    end)
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end
end
