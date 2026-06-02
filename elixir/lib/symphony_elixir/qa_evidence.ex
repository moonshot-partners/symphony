defmodule SymphonyElixir.QaEvidence do
  @moduledoc """
  Collects a UI-QA-self-review evidence bundle and hands it to the operational view.

  Reads `qa.evidence_subpath` from the active workflow config (defaults to
  `fe-next-app/qa-evidence`) and looks inside the agent's workspace for that
  directory — screenshots, a session `.webm`, a `qa-report.md` table. When the
  agent attaches its PR, the orchestrator calls `maybe_publish/2`: if the
  directory exists, the bundle is published to the optional operational view,
  where the proof surfaces in the cockpit detail. It is no longer posted as a
  tracker comment — Linear stays a clean control plane.

  Fire-and-forget — any failure is logged, never fatal to the completion path.
  """

  require Logger

  alias SymphonyElixir.{Config, OperationalView}

  @spec maybe_publish(String.t() | nil, String.t() | nil, keyword()) :: :ok
  def maybe_publish(issue_id, workspace_path, opts \\ [])

  @spec maybe_publish(String.t(), String.t() | nil, keyword()) :: :ok
  def maybe_publish(issue_id, workspace_path, opts)
      when is_binary(issue_id) and is_list(opts) do
    pending_dir = pending_publish_path(issue_id)

    # SODEV-881: continuation retry wipes the workspace between the agent's
    # PR-attach exit and the reconcile loop's pr_sync_fn → maybe_publish call.
    # If `stage_pending_publish/2` ran before the wipe, the staged copy at
    # `pending_dir` survives and is the authoritative source. Otherwise fall
    # back to live workspace paths (Phase D: one path per configured subpath).
    source_dirs =
      cond do
        File.dir?(pending_dir) -> [pending_dir]
        is_binary(workspace_path) -> evidence_source_dirs(workspace_path)
        true -> []
      end

    case stage_evidence(source_dirs) do
      {:ok, staging_dir} ->
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          try do
            publish(issue_id, staging_dir, opts)
          after
            File.rm_rf(staging_dir)
            File.rm_rf(pending_dir)
          end
        end)

      :no_evidence ->
        :ok
    end

    :ok
  end

  def maybe_publish(_issue_id, _workspace_path, _opts), do: :ok

  @doc """
  Snapshot the agent's `qa-evidence/` directory to a deterministic per-issue
  tmp path so it survives a workspace wipe.

  Called from `RetryDispatch.handle_active_retry/5` right before
  `WorkspaceCleanup.cleanup_for_identifier/2` nukes the workspace on a
  continuation retry. Subsequent `maybe_publish/3` calls for the same
  `issue_id` will prefer the staged copy over the (now-empty) workspace.
  """
  @spec stage_pending_publish(String.t() | nil, String.t() | nil) :: :ok
  def stage_pending_publish(issue_id, workspace_path)
      when is_binary(issue_id) and is_binary(workspace_path) do
    sources = evidence_source_dirs(workspace_path) |> Enum.filter(&File.dir?/1)
    if sources != [], do: snapshot_to_pending(issue_id, sources)
    :ok
  end

  def stage_pending_publish(_issue_id, _workspace_path), do: :ok

  defp snapshot_to_pending(issue_id, source_dirs) do
    target = pending_publish_path(issue_id)
    File.rm_rf(target)
    File.mkdir_p!(target)

    copied_any =
      Enum.reduce(source_dirs, false, fn source_dir, copied? ->
        case File.ls(source_dir) do
          {:ok, names} ->
            Enum.each(names, &copy_pending(&1, source_dir, target))
            copied? or names != []

          _ ->
            copied?
        end
      end)

    if copied_any do
      Logger.info("QA evidence staged for pending publish issue_id=#{issue_id} target=#{target}")
    else
      File.rm_rf(target)
    end
  end

  defp copy_pending(name, source_dir, target) do
    src = Path.join(source_dir, name)
    if File.regular?(src), do: File.cp!(src, Path.join(target, name))
  end

  defp evidence_source_dirs(workspace_path) do
    Config.qa_evidence_subpaths()
    |> Enum.map(&Path.join(workspace_path, &1))
  end

  defp pending_publish_path(issue_id) do
    Path.join(System.tmp_dir!(), "symphony-qa-staged-#{issue_id}")
  end

  defp stage_evidence(source_dirs) when is_list(source_dirs) do
    case Enum.filter(source_dirs, &File.dir?/1) do
      [] -> :no_evidence
      dirs -> do_stage(dirs)
    end
  end

  defp do_stage(dirs) do
    staging_dir =
      Path.join(System.tmp_dir!(), "symphony-qa-evidence-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(staging_dir),
         {:ok, total} when total > 0 <- copy_all(dirs, staging_dir) do
      {:ok, staging_dir}
    else
      _ ->
        File.rm_rf(staging_dir)
        :no_evidence
    end
  end

  defp copy_all(dirs, staging_dir) do
    total =
      Enum.reduce(dirs, 0, fn dir, acc ->
        case File.ls(dir) do
          {:ok, names} ->
            Enum.each(names, &copy_file(&1, dir, staging_dir))
            acc + length(names)

          _ ->
            acc
        end
      end)

    {:ok, total}
  end

  defp copy_file(name, source_dir, staging_dir) do
    src = Path.join(source_dir, name)
    if File.regular?(src), do: File.cp!(src, Path.join(staging_dir, name))
  end

  # Hand the staged bundle to the cockpit store. `opts` (e.g. parent_id) is a
  # tracker-comment leftover, now ignored — evidence no longer touches Linear.
  @doc false
  @spec publish(String.t(), Path.t(), keyword()) :: :ok
  def publish(issue_id, dir, _opts \\ []) do
    OperationalView.publish_evidence(issue_id, dir)
  end
end
