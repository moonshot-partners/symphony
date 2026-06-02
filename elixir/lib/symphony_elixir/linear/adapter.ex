defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, FetchCache}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!, $parentId: String) {
    commentCreate(input: {issueId: $issueId, body: $body, parentId: $parentId}) {
      success
      comment {
        id
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @issue_comments_query """
  query SymphonyIssueComments($issueId: String!, $after: String) {
    issue(id: $issueId) {
      comments(first: 100, after: $after) {
        nodes {
          id
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @delete_comment_mutation """
  mutation SymphonyDeleteComment($commentId: String!) {
    commentDelete(id: $commentId) {
      success
    }
  }
  """

  @issue_attachments_query """
  query SymphonyIssueAttachments($issueId: String!, $after: String) {
    issue(id: $issueId) {
      attachments(first: 100, after: $after) {
        nodes {
          id
          url
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @delete_attachment_mutation """
  mutation SymphonyDeleteAttachment($attachmentId: String!) {
    attachmentDelete(id: $attachmentId) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  # SYM rate-limit fix: the dispatch + reconciler scans fire every poll tick,
  # so their request count scaled with poll frequency and pinned the Linear
  # 2500 req/hr cap. Memoize them for a short TTL (FetchCache) to collapse
  # several ticks into one request. `fetch_issue_states_by_ids` stays uncached
  # because the dispatch-gate revalidation needs the live state.
  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues,
    do: FetchCache.fetch(:candidate_issues, fn -> client_module().fetch_candidate_issues() end)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states),
    do: FetchCache.fetch({:issues_by_states, states}, fn -> client_module().fetch_issues_by_states(states) end)

  @spec fetch_recent_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_recent_issues_by_states(states), do: client_module().fetch_recent_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_comment(issue_id, body, opts \\ [])
      when is_binary(issue_id) and is_binary(body) and is_list(opts) do
    parent_id =
      case Keyword.get(opts, :parent_id) do
        id when is_binary(id) -> id
        _ -> nil
      end

    case client_module().graphql(@create_comment_mutation, %{
           issueId: issue_id,
           body: body,
           parentId: parent_id
         }) do
      {:ok, response} ->
        with true <- get_in(response, ["data", "commentCreate", "success"]) == true,
             comment_id when is_binary(comment_id) <-
               get_in(response, ["data", "commentCreate", "comment", "id"]) do
          {:ok, comment_id}
        else
          _ -> {:error, :comment_create_failed}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :comment_create_failed}
    end
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    case client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}) do
      {:ok, response} ->
        if get_in(response, ["data", "commentUpdate", "success"]) == true do
          :ok
        else
          {:error, :comment_update_failed}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :comment_update_failed}
    end
  end

  @spec delete_issue_comments(String.t()) :: :ok | {:error, term()}
  def delete_issue_comments(issue_id) when is_binary(issue_id) do
    with {:ok, comment_ids} <- list_comment_ids(issue_id) do
      failures =
        comment_ids
        |> Enum.map(&delete_comment/1)
        |> Enum.reject(&match?(:ok, &1))

      case failures do
        [] -> :ok
        _ -> {:error, {:comment_delete_failed, failures}}
      end
    end
  end

  @spec delete_issue_pr_attachments(String.t()) :: :ok | {:error, term()}
  def delete_issue_pr_attachments(issue_id) when is_binary(issue_id) do
    with {:ok, attachments} <- list_attachments(issue_id) do
      failures =
        attachments
        |> Enum.filter(&github_pr_attachment?/1)
        |> Enum.map(&delete_attachment/1)
        |> Enum.reject(&match?(:ok, &1))

      case failures do
        [] -> :ok
        _ -> {:error, {:attachment_delete_failed, failures}}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp list_comment_ids(issue_id, after_cursor \\ nil, acc \\ []) do
    case client_module().graphql(@issue_comments_query, %{issueId: issue_id, after: after_cursor}) do
      {:ok, response} ->
        comments = get_in(response, ["data", "issue", "comments"]) || %{}
        nodes = Map.get(comments, "nodes", [])
        page_info = Map.get(comments, "pageInfo", %{})

        ids =
          Enum.flat_map(nodes, fn
            %{"id" => id} when is_binary(id) -> [id]
            _ -> []
          end)

        if Map.get(page_info, "hasNextPage") == true and is_binary(Map.get(page_info, "endCursor")) do
          list_comment_ids(issue_id, Map.get(page_info, "endCursor"), acc ++ ids)
        else
          {:ok, acc ++ ids}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :comment_lookup_failed}
    end
  end

  defp delete_comment(comment_id) do
    case client_module().graphql(@delete_comment_mutation, %{commentId: comment_id}) do
      {:ok, response} ->
        if get_in(response, ["data", "commentDelete", "success"]) == true do
          :ok
        else
          {:error, {:comment_delete_failed, comment_id}}
        end

      {:error, reason} ->
        {:error, {comment_id, reason}}

      _ ->
        {:error, {:comment_delete_failed, comment_id}}
    end
  end

  defp list_attachments(issue_id, after_cursor \\ nil, acc \\ []) do
    case client_module().graphql(@issue_attachments_query, %{issueId: issue_id, after: after_cursor}) do
      {:ok, response} ->
        attachments = get_in(response, ["data", "issue", "attachments"]) || %{}
        nodes = Map.get(attachments, "nodes", [])
        page_info = Map.get(attachments, "pageInfo", %{})

        normalized =
          Enum.flat_map(nodes, fn
            %{"id" => id, "url" => url} when is_binary(id) and is_binary(url) ->
              [%{id: id, url: url}]

            _ ->
              []
          end)

        if Map.get(page_info, "hasNextPage") == true and is_binary(Map.get(page_info, "endCursor")) do
          list_attachments(issue_id, Map.get(page_info, "endCursor"), acc ++ normalized)
        else
          {:ok, acc ++ normalized}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :attachment_lookup_failed}
    end
  end

  defp github_pr_attachment?(%{url: url}) when is_binary(url) do
    String.match?(url, ~r{^https://github\.com/[^/]+/[^/]+/pull/\d+(?:/|$)}i)
  end

  defp github_pr_attachment?(_), do: false

  defp delete_attachment(%{id: attachment_id}) do
    case client_module().graphql(@delete_attachment_mutation, %{attachmentId: attachment_id}) do
      {:ok, response} ->
        if get_in(response, ["data", "attachmentDelete", "success"]) == true do
          :ok
        else
          {:error, {:attachment_delete_failed, attachment_id}}
        end

      {:error, reason} ->
        {:error, {attachment_id, reason}}

      _ ->
        {:error, {:attachment_delete_failed, attachment_id}}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
