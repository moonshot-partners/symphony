defmodule SymphonyElixir.Linear.Normalizer do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue

  @github_pr_url ~r{^https://github\.com/[^/]+/(?<repo>[^/]+)/pull/\d+(?:/|$)}i

  @spec normalize_issue(map(), map() | nil) :: Issue.t() | nil
  def normalize_issue(issue, routing_filter) when is_map(issue) do
    assignee = issue["assignee"]
    labels = extract_labels(issue)

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      state_type: get_in(issue, ["state", "type"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      assignee_name: assignee_field(assignee, "name"),
      assignee_display_name: assignee_field(assignee, "displayName"),
      blocked_by: extract_blockers(issue),
      labels: labels,
      repos: extract_repos(issue),
      assigned_to_worker: matches_routing_filter?(assignee, labels, routing_filter),
      has_pr_attachment: pr_attachment?(issue),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  def normalize_issue(_issue, _routing_filter), do: nil

  @doc """
  Extracts GitHub PR attachments from a raw Linear issue payload into the
  normalized `[%{name, pr: %{url, merged, review}}]` shape consumed by the board
  presenter. Non-PR URLs are ignored. Duplicate PR URLs collapse to one entry.
  Merge/review fields default to `false`/`nil` and are filled by
  `Symphony.GitHub.PrStatus` enrichment downstream.
  """
  @spec extract_repos(map()) :: [Issue.repo()]
  def extract_repos(%{"attachments" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.flat_map(fn
      %{"url" => url} when is_binary(url) ->
        case Regex.named_captures(@github_pr_url, url) do
          %{"repo" => repo} -> [{repo, url}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(fn {_repo, url} -> url end)
    |> Enum.map(fn {repo, url} ->
      %{name: repo, pr: %{url: url, merged: false, review: nil}}
    end)
  end

  def extract_repos(_issue), do: []

  defp matches_routing_filter?(_assignee, _labels, nil), do: true
  defp matches_routing_filter?(_assignee, _labels, %{assignee: nil, label: nil}), do: true

  defp matches_routing_filter?(_assignee, labels, %{assignee: nil, label: label})
       when is_binary(label) do
    label in labels
  end

  defp matches_routing_filter?(assignee, _labels, %{assignee: assignee_filter, label: nil}) do
    assigned_to_worker?(assignee, assignee_filter)
  end

  defp matches_routing_filter?(assignee, labels, %{assignee: assignee_filter, label: label})
       when is_binary(label) do
    label in labels and assigned_to_worker?(assignee, assignee_filter)
  end

  defp matches_routing_filter?(_assignee, _labels, _routing_filter), do: false

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_match_candidates()
    |> Enum.any?(&MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_match_candidates(%{} = assignee) do
    Enum.flat_map(["id", "email", "name", "displayName"], fn field ->
      case normalize_assignee_match_value(assignee[field]) do
        nil -> []
        value -> [String.downcase(value)]
      end
    end)
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp pr_attachment?(%{"attachments" => %{"nodes" => nodes}}) when is_list(nodes) do
    Enum.any?(nodes, fn
      %{"url" => url} when is_binary(url) -> Regex.match?(@github_pr_url, url)
      _ -> false
    end)
  end

  defp pr_attachment?(_issue), do: false

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
