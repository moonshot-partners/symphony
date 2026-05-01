defmodule SymphonyElixir.GitHub.PrStatus do
  @moduledoc """
  Fetches GitHub PR merge + review status used to enrich `repos[].pr` on board
  payloads. Hits the REST `/repos/:owner/:repo/pulls/:number` endpoint; the
  review_decision field is reachable only via GraphQL, so the REST flow infers a
  coarse review state from `draft`/`merged`/review-comments and leaves nuanced
  cases as `nil` until a GraphQL enrichment lands.
  """

  @api "https://api.github.com"

  @type result :: %{merged: boolean(), review: String.t() | nil}

  @spec fetch(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def fetch(owner, repo, number, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(number) do
    url = "#{@api}/repos/#{owner}/#{repo}/pulls/#{number}"
    req_opts = Keyword.merge([url: url, headers: headers()], opts)

    case Req.get(req_opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{merged: body["merged"] == true, review: review_from_body(body)}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_for_url(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def fetch_for_url(url, opts \\ []) when is_binary(url) do
    case Regex.run(~r{^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)}, url) do
      [_, owner, repo, number] -> fetch(owner, repo, String.to_integer(number), opts)
      _ -> {:error, :invalid_url}
    end
  end

  defp headers do
    base = [{"Accept", "application/vnd.github+json"}]

    case System.get_env("GITHUB_TOKEN") do
      nil -> base
      "" -> base
      token -> [{"Authorization", "Bearer #{token}"} | base]
    end
  end

  defp review_from_body(%{"merged" => true}), do: nil
  defp review_from_body(%{"draft" => true}), do: "draft"
  defp review_from_body(_body), do: nil
end
