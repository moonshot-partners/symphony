defmodule SymphonyElixir.Linear.BoardClient do
  @moduledoc """
  Workspace-wide read for the kanban board.

  Unlike `SymphonyElixir.Linear.Client.fetch_issues_by_states/1`, this client
  does NOT filter by `project_slug` or `assignee`. It returns every issue in the
  Linear workspace whose state name is in the requested list, ordered newest
  first (descending `createdAt`), capped at `limit` rows in a single GraphQL
  request to keep payloads bounded.

  Used only by the read-only board API. Orchestrator dispatch keeps using
  `Client.fetch_candidate_issues/0`, which still applies project + assignee
  filters.
  """

  alias SymphonyElixir.{Config, Linear.Client, Linear.Issue}

  @query """
  query SymphonyBoardWorkspace($stateNames: [String!]!, $first: Int!) {
    issues(
      filter: {state: {name: {in: $stateNames}}}
      first: $first
      orderBy: createdAt
    ) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
          type
        }
        branchName
        url
        assignee {
          id
          email
          name
          displayName
        }
        labels {
          nodes {
            name
          }
        }
        attachments(first: 25) {
          nodes {
            url
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @spec fetch_all_issues_by_states([String.t()], pos_integer()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_all_issues_by_states(state_names, limit)
      when is_list(state_names) and is_integer(limit) and limit > 0 do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      _api_key ->
        fetch_all_issues_by_states_for_test(state_names, limit, &Client.graphql/2)
    end
  end

  @doc false
  @spec fetch_all_issues_by_states_for_test(
          [String.t()],
          pos_integer(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_all_issues_by_states_for_test(state_names, limit, graphql_fun)
      when is_list(state_names) and is_integer(limit) and limit > 0 and
             is_function(graphql_fun, 2) do
    normalized = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      case graphql_fun.(@query, %{stateNames: normalized, first: limit}) do
        {:ok, body} -> decode_response(body)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_response(%{"data" => %{"issues" => %{"nodes" => nodes}}})
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&Client.normalize_issue_for_test/1)
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp decode_response(_body), do: {:error, :invalid_linear_response}
end
