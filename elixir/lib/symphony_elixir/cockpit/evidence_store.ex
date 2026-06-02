defmodule SymphonyElixir.Cockpit.EvidenceStore do
  @moduledoc """
  On-box store for QA evidence bundles, served read-only by the cockpit instead
  of uploaded to the tracker. This is what lets the agent keep the tracker a
  clean control plane: the proof (screenshots + session video + the QA report)
  lives here and surfaces in the cockpit, not as a comment on the ticket.

  - `publish/2` copies an agent's evidence directory into a per-issue folder and
    writes an `index.json` manifest (gallery items + the inline report text).
  - `read/1` returns that manifest for the board build.
  - `file_path/2` resolves a stored file for serving, refusing path traversal.

  The store root is `SYMPHONY_COCKPIT_EVIDENCE_DIR` (default
  `/opt/symphony/state/evidence`). Keyed by the orchestrator's internal issue
  id, the same key the board matches on.
  """

  require Logger

  @default_dir "/opt/symphony/state/evidence"
  @image_exts ~w(.png .jpg .jpeg .gif .webp)
  @video_exts ~w(.webm .mp4)
  @report_name "qa-report.md"
  @max_items 30

  @spec dir() :: String.t()
  def dir, do: System.get_env("SYMPHONY_COCKPIT_EVIDENCE_DIR") || @default_dir

  @doc """
  Copy the gallery files (images + session video) from `src_dir` into the
  per-issue store, replacing any previous bundle, and write the manifest with
  the QA report inline. Fire-and-forget: returns `:ok` even when nothing copies.
  """
  @spec publish(String.t(), Path.t()) :: :ok
  def publish(issue_id, src_dir) when is_binary(issue_id) do
    dest = issue_dir(issue_id)
    File.rm_rf(dest)
    File.mkdir_p!(dest)

    names = list(src_dir)
    items = gallery(names, src_dir, dest)
    report = report_content(names, src_dir)

    File.write!(
      Path.join(dest, "index.json"),
      Jason.encode!(%{"items" => items, "report" => report})
    )

    Logger.info("QA evidence stored issue_id=#{issue_id} items=#{length(items)} report=#{report != nil} dir=#{dest}")

    :ok
  end

  @doc """
  Manifest for an issue: `%{"items" => [%{"name", "kind"}], "report" => string | nil}`.
  Empty manifest when the issue has no stored bundle.
  """
  @spec read(String.t()) :: %{required(String.t()) => term()}
  def read(issue_id) when is_binary(issue_id) do
    with {:ok, content} <- File.read(Path.join(issue_dir(issue_id), "index.json")),
         {:ok, %{"items" => items} = manifest} when is_list(items) <- Jason.decode(content) do
      %{"items" => items, "report" => Map.get(manifest, "report")}
    else
      _ -> empty()
    end
  end

  @doc """
  Remove every stored evidence file for an issue.

  This is used by destructive reruns so the cockpit reflects a genuinely fresh
  attempt instead of showing proof from a previous run.
  """
  @spec delete(String.t()) :: :ok
  def delete(issue_id) when is_binary(issue_id) do
    case File.rm_rf(issue_dir(issue_id)) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("QA evidence delete failed issue_id=#{issue_id} path=#{path} reason=#{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Absolute path of a stored file, or `nil` if it does not exist or the name
  tries to escape the issue folder (path traversal).
  """
  @spec file_path(String.t(), String.t()) :: String.t() | nil
  def file_path(issue_id, name) when is_binary(issue_id) and is_binary(name) do
    path = Path.join(issue_dir(issue_id), name)

    if name == Path.basename(name) and File.regular?(path), do: path, else: nil
  end

  defp empty, do: %{"items" => [], "report" => nil}

  defp issue_dir(issue_id), do: Path.join(dir(), sanitize(issue_id))

  defp sanitize(issue_id), do: String.replace(issue_id, ~r/[^A-Za-z0-9._-]/, "_")

  defp list(src_dir) do
    case File.ls(src_dir) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  defp gallery(names, src_dir, dest) do
    names
    |> Enum.flat_map(fn name ->
      case kind(name) do
        nil -> []
        kind -> copy_item(name, kind, src_dir, dest)
      end
    end)
    |> Enum.take(@max_items)
  end

  defp copy_item(name, kind, src_dir, dest) do
    src = Path.join(src_dir, name)

    if File.regular?(src) and File.cp(src, Path.join(dest, name)) == :ok do
      [%{"name" => name, "kind" => kind}]
    else
      []
    end
  end

  defp report_content(names, src_dir) do
    if @report_name in names do
      case File.read(Path.join(src_dir, @report_name)) do
        {:ok, content} -> content
        _ -> nil
      end
    end
  end

  defp kind(name) do
    ext = name |> Path.extname() |> String.downcase()

    cond do
      ext in @image_exts -> "image"
      ext in @video_exts -> "video"
      true -> nil
    end
  end
end
