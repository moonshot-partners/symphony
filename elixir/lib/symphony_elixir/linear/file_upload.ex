defmodule SymphonyElixir.Linear.FileUpload do
  @moduledoc """
  Uploads a local file to Linear's storage.

  Two steps: the `fileUpload` GraphQL mutation hands back a presigned upload URL
  plus the headers it must be PUT with, then we PUT the bytes there. The returned
  `assetUrl` is usable directly in comment markdown (`![](assetUrl)`), which is
  how the orchestrator embeds QA self-review screenshots on the Linear ticket.
  """

  alias SymphonyElixir.Linear.Client

  @content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webm" => "video/webm",
    ".mp4" => "video/mp4",
    ".md" => "text/markdown",
    ".json" => "application/json",
    ".txt" => "text/plain",
    ".log" => "text/plain",
    ".zip" => "application/zip"
  }

  @mutation """
  mutation SymphonyFileUpload($contentType: String!, $filename: String!, $size: Int!) {
    fileUpload(contentType: $contentType, filename: $filename, size: $size) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers { key value }
      }
    }
  }
  """

  @spec upload(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def upload(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path),
         content_type <- content_type_for(path),
         {:ok, body} <-
           Client.graphql(@mutation, %{
             contentType: content_type,
             filename: Path.basename(path),
             size: byte_size(bytes)
           }),
         {:ok, upload_url, asset_url, headers} <- extract_target(body),
         :ok <- put_bytes(upload_url, content_type, headers, bytes) do
      {:ok, asset_url}
    end
  end

  defp extract_target(%{
         "data" => %{
           "fileUpload" => %{
             "success" => true,
             "uploadFile" => %{"uploadUrl" => upload_url, "assetUrl" => asset_url} = upload_file
           }
         }
       })
       when is_binary(upload_url) and is_binary(asset_url) do
    headers =
      upload_file
      |> Map.get("headers", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"key" => k, "value" => v} when is_binary(k) and is_binary(v) -> [{k, v}]
        _ -> []
      end)

    {:ok, upload_url, asset_url, headers}
  end

  defp extract_target(%{"errors" => errors}), do: {:error, {:linear_graphql_errors, errors}}
  defp extract_target(other), do: {:error, {:file_upload_bad_response, other}}

  defp put_bytes(url, content_type, headers, bytes) do
    req_headers = [{"Content-Type", content_type} | headers]

    case Req.put(url, headers: req_headers, body: bytes, connect_options: [timeout: 30_000]) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, response} -> {:error, {:storage_put_status, response.status}}
      {:error, reason} -> {:error, {:storage_put_request, reason}}
    end
  end

  @doc false
  def content_type_for(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end
end
