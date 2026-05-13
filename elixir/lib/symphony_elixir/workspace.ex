defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Agent runners.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @marker_relpath ".symphony/after_create_ok"

  @spec create_for_issue(map() | String.t() | nil, term()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, _worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id),
           :ok <- validate_workspace_path(workspace),
           {:ok, workspace} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace}
  end

  @spec remove(Path.t(), term()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, _worker_host \\ nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term(), term()) :: :ok
  def remove_issue_workspaces(identifier, _worker_host \\ nil)

  def remove_issue_workspaces(identifier, _worker_host) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id) do
      {:ok, workspace} -> remove(workspace)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, term()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, _worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil -> :ok
      command -> run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, term()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, _worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context) do
    case Config.settings!().hooks.after_create do
      nil -> :ok
      command -> run_after_create_hook(workspace, issue_context, command)
    end
  end

  defp run_after_create_hook(workspace, issue_context, command) do
    if marker_matches?(workspace, command) do
      :ok
    else
      with :ok <- run_hook(command, workspace, issue_context, "after_create") do
        write_marker(workspace, command)
        :ok
      end
    end
  end

  defp marker_path(workspace), do: Path.join(workspace, @marker_relpath)

  defp marker_matches?(workspace, command) do
    case File.read(marker_path(workspace)) do
      {:ok, contents} -> String.trim(contents) == hook_hash(command)
      _ -> false
    end
  end

  defp write_marker(workspace, command) do
    marker = marker_path(workspace)
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, hook_hash(command) <> "\n")
  end

  defp hook_hash(command) do
    :crypto.hash(:sha256, command) |> Base.encode16(case: :lower)
  end

  defp maybe_run_before_remove_hook(workspace) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("bash", ["-lc", command],
          cd: workspace,
          stderr_to_stdout: true,
          env: hook_env()
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  @doc """
  Default environment overrides for every workspace hook.

  `NPM_CONFIG_IGNORE_SCRIPTS=1` disables npm lifecycle scripts (pre/post
  install, prepare, etc.) by default. Lifecycle scripts that depend on
  secrets the workspace does not carry — `@sentry/cli` is the canonical
  offender — can silently corrupt `node_modules` when they fail at the
  postinstall stage. Skipping them keeps the install reproducible across
  agent runs.

  A workflow that genuinely needs a lifecycle script can override per-call
  with `npm ci --foreground-scripts` or by unsetting the var in the hook
  body. The recommended path is to add the script step explicitly in the
  hook so it cannot fail silently.
  """
  @spec hook_env() :: [{binary(), binary()}]
  def hook_env do
    [
      {"NPM_CONFIG_IGNORE_SCRIPTS", "1"}
    ]
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
