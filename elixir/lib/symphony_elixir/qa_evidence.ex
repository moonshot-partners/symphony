defmodule SymphonyElixir.QaEvidence do
  @moduledoc """
  Publishes a UI-QA-self-review evidence bundle to a Linear ticket.

  The `schools-out` workflow's "UI QA self-review" step (see
  `WORKFLOW.schools-out.md` rule 5) leaves a `fe-next-app/qa-evidence/`
  directory in the agent's workspace — screenshots, a session `.webm`, a
  `qa-report.md` table. When the agent attaches its PR, the orchestrator calls
  `maybe_publish/2`: if that directory exists, the screenshots are uploaded to
  Linear and posted as a comment on the ticket (with the report table inline) so
  the proof lives on the ticket the PM looks at, not only inside the PR.

  Fire-and-forget — any failure is logged, never fatal to the completion path.
  """

  require Logger

  alias SymphonyElixir.Tracker

  @evidence_subpath "fe-next-app/qa-evidence"
  @image_exts ~w(.png .jpg .jpeg .gif)
  @max_images 20

  @spec maybe_publish(String.t() | nil, String.t() | nil, keyword()) :: :ok
  def maybe_publish(issue_id, workspace_path, opts \\ [])

  def maybe_publish(issue_id, workspace_path, opts)
      when is_binary(issue_id) and is_binary(workspace_path) and is_list(opts) do
    source_dir = Path.join(workspace_path, @evidence_subpath)

    case stage_evidence(source_dir) do
      {:ok, staging_dir} ->
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          try do
            publish(issue_id, staging_dir, opts)
          after
            File.rm_rf(staging_dir)
          end
        end)

      :no_evidence ->
        :ok
    end

    :ok
  end

  def maybe_publish(_issue_id, _workspace_path, _opts), do: :ok

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
    case File.ls(source_dir) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          src = Path.join(source_dir, name)
          dst = Path.join(staging_dir, name)
          if File.regular?(src), do: File.cp!(src, dst)
        end)

        {:ok, names}

      err ->
        err
    end
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
      "## QA self-review evidence",
      if(report, do: "\n" <> String.trim_trailing(report)),
      "\n### Screenshots\n",
      screenshots_block(uploaded),
      if(video_url, do: "\n[session.webm](#{video_url}) — full session recording"),
      if(trace_url,
        do: "\n[session.zip](#{trace_url}) — Playwright trace (drag into https://trace.playwright.dev)"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

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
    Enum.map_join(uploaded, "\n\n", fn {name, url} -> "**#{name}**\n\n![#{name}](#{url})" end)
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
