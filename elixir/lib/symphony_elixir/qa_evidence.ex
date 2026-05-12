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

  @spec maybe_publish(String.t() | nil, String.t() | nil) :: :ok
  def maybe_publish(issue_id, workspace_path)
      when is_binary(issue_id) and is_binary(workspace_path) do
    dir = Path.join(workspace_path, @evidence_subpath)

    if File.dir?(dir) do
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> publish(issue_id, dir) end)
    end

    :ok
  end

  def maybe_publish(_issue_id, _workspace_path), do: :ok

  @doc false
  @spec publish(String.t(), Path.t()) :: :ok
  def publish(issue_id, dir) do
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

    video_url = maybe_upload_video(Path.join(dir, "session.webm"))

    case Tracker.create_comment(issue_id, build_comment(report, uploaded, video_url)) do
      {:ok, _id} ->
        Logger.info("QA evidence published issue_id=#{issue_id} images=#{length(uploaded)} video=#{video_url != nil}")
        :ok

      {:error, reason} ->
        Logger.warning("QA evidence comment failed issue_id=#{issue_id} reason=#{inspect(reason)}")
        :ok
    end
  end

  @doc false
  @spec build_comment(String.t() | nil, [{String.t(), String.t()}], String.t() | nil) :: String.t()
  def build_comment(report, uploaded, video_url) do
    [
      "## QA self-review evidence",
      if(report, do: "\n" <> String.trim_trailing(report)),
      "\n### Screenshots\n",
      screenshots_block(uploaded),
      if(video_url, do: "\n[session.webm](#{video_url}) — full session recording")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp maybe_upload_video(path) do
    if File.regular?(path) do
      case upload_module().upload(path) do
        {:ok, url} ->
          url

        {:error, reason} ->
          Logger.warning("QA evidence video upload failed reason=#{inspect(reason)}")
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
