defmodule SymphonyElixir.Cockpit.BoardView do
  @moduledoc """
  Pure assembly of the cockpit board payload from tracker issues, the run
  ledger, and the tracker state config. Read-only: produces the JSON shape the
  cockpit UI validates (see the dashboard's Zod `BoardPayload`). No agent state
  is mutated here.

  Fields that cannot be sourced cheaply and honestly are left empty/null
  (evidence, timeline, CI status, USD cost — the ledger carries tokens, not
  cost, and tokens are an unreliable cost proxy) rather than fabricated.
  """

  alias SymphonyElixir.Linear.Issue

  @default_trace_base "https://cloud.langfuse.com/trace/"

  @doc """
  Every state the board cares about, derived from the tracker config and
  deduplicated. `nil` slots (unconfigured states) are dropped.
  """
  @spec relevant_states(map()) :: [String.t()]
  def relevant_states(tracker) do
    (list(tracker.active_states) ++
       [
         tracker.on_complete_state,
         tracker.on_exhaust_state,
         tracker.on_promote_state,
         tracker.on_pr_merge_state,
         tracker.on_reject_state
       ] ++
       list(tracker.terminal_states))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Issues whose CI status is worth fetching over the network: everything not in
  a terminal state. A Done/Cancelled ticket's PR checks are settled and not
  actionable, so the board skips the (per-PR `gh`) CI lookup for them. This
  keeps the per-build CI work bounded by the active pipeline instead of the
  unbounded history of finished work — which otherwise pushed `assemble_board`
  past the board cache's 30s call timeout once enough Done tickets piled up.
  """
  @spec ci_candidates([Issue.t()], map()) :: [Issue.t()]
  def ci_candidates(issues, tracker) do
    terminal = MapSet.new(list(tracker.terminal_states))
    Enum.reject(issues, fn issue -> MapSet.member?(terminal, issue.state) end)
  end

  @doc """
  Build the board payload map (string keys, JSON-ready).
  `runs` is a list of decoded ledger maps (string keys).
  `opts[:trace_base]` overrides the Langfuse trace URL prefix.
  """
  @spec assemble([Issue.t()], [map()], map(), keyword()) :: map()
  def assemble(issues, runs, tracker, opts \\ []) do
    trace_base = Keyword.get(opts, :trace_base, @default_trace_base)
    runs_by_ticket = index_runs(runs)
    # Internal issue ids the orchestrator currently has an agent running on
    # (from status.json). Matched against issue.id, not the identifier.
    running = MapSet.new(list(Keyword.get(opts, :running)))
    # CI status keyed by PR url: %{url => "passing" | "pending" | "failing"}.
    ci = Map.new(Keyword.get(opts, :ci, []))
    # QA evidence manifests keyed by internal issue id (cockpit evidence store).
    evidence = Map.new(Keyword.get(opts, :evidence, []))
    # Completion summary markdown keyed by internal issue id (run summary store).
    summary = Map.new(Keyword.get(opts, :summary, []))

    %{
      "states" => %{
        "active" => list(tracker.active_states),
        "onComplete" => tracker.on_complete_state,
        "onExhaust" => tracker.on_exhaust_state,
        "onPromote" => tracker.on_promote_state,
        "onPrMerge" => tracker.on_pr_merge_state,
        "onReject" => tracker.on_reject_state,
        "terminal" => list(tracker.terminal_states),
        "upNextExtra" => list(Keyword.get(opts, :extra_up_next)),
        "doneExtra" => list(Keyword.get(opts, :extra_done))
      },
      "tickets" => Enum.map(issues, &ticket(&1, runs_by_ticket, trace_base, running, ci, evidence, summary))
    }
  end

  defp ticket(%Issue{} = issue, runs_by_ticket, trace_base, running, ci, evidence, summary) do
    run = Map.get(runs_by_ticket, issue.identifier)
    status = if MapSet.member?(running, issue.id), do: "running", else: "idle"
    manifest = Map.get(evidence, issue.id, %{})

    %{
      "id" => issue.identifier,
      "title" => issue.title,
      "state" => issue.state,
      "agent" => %{
        "status" => status,
        "turn" => run && int_field(run, "turns"),
        "maxTurns" => nil,
        "costUsd" => nil,
        "lastAction" => run && string_field(run, "outcome")
      },
      "pr" => pr(issue, ci),
      "evidence" => evidence_items(issue.id, manifest),
      "report" => Map.get(manifest, "report"),
      "summary" => Map.get(summary, issue.id),
      "url" => issue.url,
      "traceUrl" => trace_url(run, trace_base),
      "updatedAt" => issue.updated_at || ""
    }
  end

  # Gallery items from the store manifest, each pointing at the cockpit's
  # same-origin evidence proxy (`/api/evidence/<issue id>/<file>`).
  defp evidence_items(issue_id, manifest) do
    manifest
    |> Map.get("items", [])
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      name = item["name"]

      %{
        "id" => "#{issue_id}-#{index}",
        "kind" => item["kind"],
        "name" => name,
        "url" => "/api/evidence/#{URI.encode(issue_id)}/#{URI.encode(name)}"
      }
    end)
  end

  # Latest ledger row per ticket identifier (append order: last wins).
  defp index_runs(runs) do
    Enum.reduce(runs, %{}, fn run, acc ->
      case is_map(run) and run["ticket"] do
        ticket when is_binary(ticket) -> Map.put(acc, ticket, run)
        _ -> acc
      end
    end)
  end

  defp pr(%Issue{repos: repos}, ci) when is_list(repos) do
    repos
    |> Enum.map(&pr_url/1)
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> nil
      url -> %{"number" => pr_number(url), "ci" => Map.get(ci, url), "url" => url}
    end
  end

  defp pr(_, _), do: nil

  defp pr_url(%{pr: %{url: url}}) when is_binary(url), do: url
  defp pr_url(%{"pr" => %{"url" => url}}) when is_binary(url), do: url
  defp pr_url(_), do: nil

  defp pr_number(url) do
    case Regex.run(~r{/(\d+)(?:$|[/?#])}, url) do
      [_, digits] -> String.to_integer(digits)
      _ -> 0
    end
  end

  defp trace_url(run, trace_base) when is_map(run) do
    case run["langfuse_trace_id"] do
      id when is_binary(id) and id != "" -> trace_base <> id
      _ -> nil
    end
  end

  defp trace_url(_run, _trace_base), do: nil

  defp int_field(run, key) do
    case run[key] do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp string_field(run, key) do
    case run[key] do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp list(nil), do: []
  defp list(value) when is_list(value), do: value
end
