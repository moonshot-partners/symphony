defmodule SymphonyElixir.QaEvidence do
  @moduledoc """
  Publishes a UI-QA-self-review evidence bundle to the tracker ticket.

  Reads `qa.evidence_subpath` from the active workflow config (defaults to
  `fe-next-app/qa-evidence`) and looks inside the agent's workspace for that
  directory — screenshots, a session `.webm`, a `qa-report.md` table. When the
  agent attaches its PR, the orchestrator calls `maybe_publish/2`: if the
  directory exists, the screenshots are uploaded and posted as a comment on
  the ticket (with the report table inline) so the proof lives on the ticket
  the PM looks at, not only inside the PR.

  Fire-and-forget — any failure is logged, never fatal to the completion path.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker

  @image_exts ~w(.png .jpg .jpeg .gif)
  @max_images 20

  @spec maybe_publish(String.t() | nil, String.t() | nil, keyword()) :: :ok
  def maybe_publish(issue_id, workspace_path, opts \\ [])

  def maybe_publish(issue_id, workspace_path, opts)
      when is_binary(issue_id) and is_list(opts) do
    pending_dir = pending_publish_path(issue_id)

    # SODEV-881: continuation retry wipes the workspace between the agent's
    # PR-attach exit and the reconcile loop's pr_sync_fn → maybe_publish call.
    # If `stage_pending_publish/2` ran before the wipe, the staged copy at
    # `pending_dir` survives and is the authoritative source. Otherwise fall
    # back to the live workspace path.
    source_dir =
      cond do
        File.dir?(pending_dir) -> pending_dir
        is_binary(workspace_path) -> Path.join(workspace_path, Config.qa_evidence_subpath())
        true -> nil
      end

    case maybe_stage(source_dir) do
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
    source_dir = Path.join(workspace_path, Config.qa_evidence_subpath())

    if File.dir?(source_dir) do
      target = pending_publish_path(issue_id)
      File.rm_rf(target)
      File.mkdir_p!(target)

      case File.ls(source_dir) do
        {:ok, names} ->
          Enum.each(names, fn name ->
            src = Path.join(source_dir, name)
            if File.regular?(src), do: File.cp!(src, Path.join(target, name))
          end)

          Logger.info("QA evidence staged for pending publish issue_id=#{issue_id} target=#{target}")

        _ ->
          File.rm_rf(target)
      end
    end

    :ok
  end

  def stage_pending_publish(_issue_id, _workspace_path), do: :ok

  defp pending_publish_path(issue_id) do
    Path.join(System.tmp_dir!(), "symphony-qa-staged-#{issue_id}")
  end

  defp maybe_stage(nil), do: :no_evidence
  defp maybe_stage(source_dir), do: stage_evidence(source_dir)

  defp stage_evidence(source_dir) do
    with true <- File.dir?(source_dir),
         staging_dir =
           Path.join(System.tmp_dir!(), "symphony-qa-evidence-#{System.unique_integer([:positive])}"),
         :ok <- File.mkdir_p(staging_dir),
         {:ok, _names} <- copy_dir(source_dir, staging_dir) do
      {:ok, staging_dir}
    else
      _ -> :no_evidence
    end
  end

  defp copy_dir(source_dir, staging_dir) do
    with {:ok, names} <- File.ls(source_dir) do
      Enum.each(names, &copy_file(&1, source_dir, staging_dir))
      {:ok, names}
    end
  end

  defp copy_file(name, source_dir, staging_dir) do
    src = Path.join(source_dir, name)
    if File.regular?(src), do: File.cp!(src, Path.join(staging_dir, name))
  end

  @doc false
  @spec publish(String.t(), Path.t(), keyword()) :: :ok
  def publish(issue_id, dir, opts \\ []) do
    images = dir |> list_files(@image_exts) |> Enum.take(@max_images)
    report = read_optional(Path.join(dir, "qa-report.md"))

    uploaded =
      Enum.flat_map(images, fn path ->
        case upload_module().upload(path) do
          {:ok, url} ->
            [{Path.basename(path), url}]

          {:error, reason} ->
            Logger.warning("QA evidence upload failed file=#{Path.basename(path)} reason=#{inspect(reason)}")
            []
        end
      end)

    video_url = maybe_upload_artifact(Path.join(dir, "session.webm"), "video")
    trace_url = maybe_upload_artifact(Path.join(dir, "session.zip"), "trace")

    parent_id = Keyword.get(opts, :parent_id)
    body = build_comment(report, uploaded, video_url, trace_url)

    case Tracker.create_comment(issue_id, body, parent_id: parent_id) do
      {:ok, _id} ->
        Logger.info(
          "QA evidence published issue_id=#{issue_id} images=#{length(uploaded)} " <>
            "video=#{video_url != nil} trace=#{trace_url != nil}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("QA evidence comment failed issue_id=#{issue_id} reason=#{inspect(reason)}")
        :ok
    end
  end

  @doc false
  @spec build_comment(
          String.t() | nil,
          [{String.t(), String.t()}],
          String.t() | nil,
          String.t() | nil
        ) :: String.t()
  def build_comment(report, uploaded, video_url, trace_url \\ nil) do
    [
      "## QA self-review" <> status_suffix(report),
      if(report, do: "\n" <> String.trim_trailing(report)),
      "\n### Screenshots\n",
      screenshots_block(uploaded),
      artifacts_line(video_url, trace_url)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp status_suffix(nil), do: ""

  defp status_suffix(report) do
    case Regex.run(~r/^- Result:\s*(PASS|FAIL|BLOCKED)\b/m, report) do
      [_, status] -> " · " <> status
      _ -> ""
    end
  end

  defp artifacts_line(nil, nil), do: nil
  defp artifacts_line(video, nil), do: "\n[session video](#{video})"
  defp artifacts_line(nil, trace), do: "\n[Playwright trace](#{trace})"
  defp artifacts_line(video, trace), do: "\n[session video](#{video})\n\n[Playwright trace](#{trace})"

  defp maybe_upload_artifact(path, label) do
    if File.regular?(path) do
      case upload_module().upload(path) do
        {:ok, url} ->
          url

        {:error, reason} ->
          Logger.warning("QA evidence #{label} upload failed reason=#{inspect(reason)}")
          nil
      end
    end
  end

  defp screenshots_block([]), do: "_(no screenshots uploaded)_"

  defp screenshots_block(uploaded) do
    Enum.map_join(uploaded, "\n", fn {name, url} -> "![#{name}](#{url})" end)
  end

  defp list_files(dir, exts) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(fn n -> String.downcase(Path.extname(n)) in exts end)
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp upload_module do
    Application.get_env(:symphony_elixir, :qa_evidence_upload_module, SymphonyElixir.Linear.FileUpload)
  end
end
