defmodule SymphonyElixir.Orchestrator.DebugBundle do
  @moduledoc """
  Builds the private agent-debug zip attached from the final Linear summary.

  The public Linear thread stays small; this bundle keeps the material that is
  useful when someone needs to debug the agent run: final turn text, captured
  AC sections, understanding.md, PR metadata, changed files, and QA artifacts.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.TurnArtifacts

  @max_text_bytes 500_000
  @max_artifact_bytes 100_000_000

  @spec create_and_upload(map(), map(), term()) :: {:ok, String.t()} | {:error, term()}
  def create_and_upload(issue, running_entry, reason) when is_map(issue) and is_map(running_entry) do
    with {:ok, zip_path} <- create(issue, running_entry, reason),
         result <- upload_module().upload(zip_path) do
      File.rm(zip_path)
      result
    else
      {:error, reason} = error ->
        Logger.warning("Debug bundle failed issue=#{identifier(issue, running_entry)} reason=#{inspect(reason)}")
        error
    end
  end

  @doc false
  @spec create(map(), map(), term()) :: {:ok, Path.t()} | {:error, term()}
  def create(issue, running_entry, reason) when is_map(issue) and is_map(running_entry) do
    zip_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-debug-#{identifier(issue, running_entry)}-#{System.unique_integer([:positive])}.zip"
      )

    entries =
      []
      |> add_text("metadata.json", metadata_json(issue, running_entry, reason))
      |> add_optional_text("last-agent-message.md", Map.get(running_entry, :last_agent_text))
      |> add_pinned_sections(running_entry)
      |> add_understanding_md(Map.get(running_entry, :workspace_path))
      |> add_qa_artifacts(Map.get(running_entry, :workspace_path))
      |> Enum.reverse()

    with {:ok, _} <- :zip.create(String.to_charlist(zip_path), entries, []) do
      {:ok, zip_path}
    end
  end

  defp metadata_json(issue, running_entry, reason) do
    %{
      issue_id: Map.get(issue, :id),
      identifier: identifier(issue, running_entry),
      issue_title: Map.get(issue, :title),
      issue_url: Map.get(issue, :url),
      target_reason: inspect(reason),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: Map.get(running_entry, :session_id),
      turn_count: Map.get(running_entry, :turn_count),
      last_agent_event: Map.get(running_entry, :last_agent_event),
      workpad_comment_id: Map.get(running_entry, :workpad_comment_id),
      pr_urls: pr_urls(issue)
    }
    |> Jason.encode!(pretty: true)
  end

  defp add_pinned_sections(entries, running_entry) do
    case Map.get(running_entry, :pinned_evidence_text) do
      %{} = sections ->
        entries
        |> add_optional_text("ac-extracted.md", Map.get(sections, "AC Extracted"))
        |> add_optional_text("ac-evidence.md", Map.get(sections, "AC Evidence"))

      _ ->
        entries
    end
  end

  defp add_understanding_md(entries, workspace_path) when is_binary(workspace_path) do
    with path when is_binary(path) <- TurnArtifacts.discover_understanding_md(workspace_path),
         {:ok, content} <- read_capped(path, @max_text_bytes) do
      add_text(entries, "understanding.md", content)
    else
      _ -> entries
    end
  end

  defp add_understanding_md(entries, _), do: entries

  defp add_qa_artifacts(entries, workspace_path) when is_binary(workspace_path) do
    Config.qa_evidence_subpaths()
    |> Enum.reduce(entries, fn subpath, acc ->
      dir = Path.join(workspace_path, subpath)

      dir
      |> regular_files_under()
      |> Enum.reduce(acc, fn path, file_acc ->
        archive_name = Path.join(["qa-evidence", subpath, Path.relative_to(path, dir)])
        add_file(file_acc, archive_name, path)
      end)
    end)
  end

  defp add_qa_artifacts(entries, _), do: entries

  defp add_file(entries, archive_name, path) do
    case read_capped(path, @max_artifact_bytes) do
      {:ok, content} ->
        add_text(entries, archive_name, content)

      {:error, reason} ->
        add_text(entries, archive_name <> ".skipped.txt", "Skipped #{path}: #{inspect(reason)}\n")
    end
  end

  defp regular_files_under(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
    else
      []
    end
  end

  defp add_optional_text(entries, _name, nil), do: entries
  defp add_optional_text(entries, name, text) when is_binary(text), do: add_text(entries, name, text)

  defp add_text(entries, name, content) when is_binary(name) and is_binary(content) do
    [{String.to_charlist(name), content} | entries]
  end

  defp read_capped(path, max_bytes) do
    with {:ok, %File.Stat{size: size}} when size <= max_bytes <- File.stat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      {:ok, %File.Stat{size: size}} -> {:error, {:too_large, size, max_bytes}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pr_urls(%{repos: repos}) when is_list(repos) do
    Enum.flat_map(repos, fn
      %{pr: %{url: url}} when is_binary(url) -> [url]
      _ -> []
    end)
  end

  defp pr_urls(_), do: []

  defp identifier(issue, running_entry) do
    Map.get(issue, :identifier) || Map.get(running_entry, :identifier) || Map.get(issue, :id) || "unknown"
  end

  defp upload_module do
    Application.get_env(:symphony_elixir, :debug_bundle_upload_module, SymphonyElixir.Linear.FileUpload)
  end
end
