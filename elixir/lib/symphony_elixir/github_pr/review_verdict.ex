defmodule SymphonyElixir.GitHubPr.ReviewVerdict do
  @moduledoc """
  Parser for the structured `claude-pr-review-verdict.json` contract.

  The artifact is the machine contract. PR comments and job summaries are human
  display surfaces and should only be used as migration fallback.
  """

  @type result ::
          {:blocking, %{count: non_neg_integer(), items: [String.t()], head_sha: String.t()}}
          | :clear
          | {:unknown, String.t()}

  @allowed_verdicts ~w(approve request_changes comment unknown)

  @doc """
  Evaluates a decoded verdict artifact against the current PR HEAD sha.

  Missing artifacts are handled by the caller as fallback-to-comment. This
  function only sees artifacts that were actually present; malformed, stale, or
  internally inconsistent artifacts therefore become `unknown`, which callers
  must treat as blocking.
  """
  @spec evaluate(map() | term(), String.t()) :: result()
  def evaluate(payload, expected_head_sha) when is_map(payload) and is_binary(expected_head_sha) do
    with :ok <- require_schema(payload),
         :ok <- require_head_sha(payload, expected_head_sha),
         {:ok, verdict} <- require_verdict(payload),
         {:ok, blocking?} <- require_blocking(payload),
         {:ok, findings} <- require_findings(payload),
         {:ok, severity_counts} <- require_severity_counts(payload) do
      classify(payload, verdict, blocking?, findings, severity_counts)
    end
  end

  def evaluate(_, _), do: {:unknown, "artifact is not a JSON object"}

  defp require_schema(%{"schema_version" => 1}), do: :ok
  defp require_schema(%{"schema_version" => _}), do: {:unknown, "unsupported schema_version"}
  defp require_schema(_), do: {:unknown, "missing schema_version"}

  defp require_head_sha(%{"head_sha" => sha}, sha), do: :ok
  defp require_head_sha(%{"head_sha" => sha}, _expected) when is_binary(sha), do: {:unknown, "stale head_sha"}
  defp require_head_sha(_, _), do: {:unknown, "missing head_sha"}

  defp require_verdict(%{"verdict" => verdict}) when verdict in @allowed_verdicts, do: {:ok, verdict}
  defp require_verdict(%{"verdict" => _}), do: {:unknown, "unsupported verdict"}
  defp require_verdict(_), do: {:unknown, "missing verdict"}

  defp require_blocking(%{"blocking" => blocking?}) when is_boolean(blocking?), do: {:ok, blocking?}
  defp require_blocking(_), do: {:unknown, "missing blocking"}

  defp require_findings(%{"findings" => findings}) when is_list(findings), do: {:ok, findings}
  defp require_findings(_), do: {:unknown, "missing findings"}

  defp require_severity_counts(%{"severity_counts" => counts}) when is_map(counts), do: {:ok, counts}
  defp require_severity_counts(_), do: {:unknown, "missing severity_counts"}

  defp classify(_payload, "unknown", _blocking?, _findings, _counts), do: {:unknown, "verdict unknown"}

  defp classify(payload, "request_changes", blocking?, findings, counts) do
    blocking_findings = Enum.filter(findings, &blocking_finding?/1)

    if blocking? or blocking_findings != [] do
      {:blocking,
       %{
         count: critical_count(counts, blocking_findings),
         items: Enum.map(blocking_findings, &format_finding/1),
         head_sha: payload["head_sha"]
       }}
    else
      {:unknown, "request_changes without blocking findings"}
    end
  end

  defp classify(_payload, verdict, true, _findings, _counts) when verdict in ["approve", "comment"] do
    {:unknown, "#{verdict} verdict marked blocking"}
  end

  defp classify(_payload, verdict, _blocking?, findings, _counts) when verdict in ["approve", "comment"] do
    if Enum.any?(findings, &blocking_finding?/1),
      do: {:unknown, "#{verdict} verdict contains blocking findings"},
      else: :clear
  end

  defp blocking_finding?(%{"blocking" => true}), do: true
  defp blocking_finding?(_), do: false

  defp critical_count(counts, blocking_findings) do
    case Map.get(counts, "critical") do
      n when is_integer(n) and n >= 0 -> n
      _ -> length(blocking_findings)
    end
  end

  defp format_finding(finding) when is_map(finding) do
    title = string_field(finding, "title", "blocking finding")
    agent = string_field(finding, "agent", "claude-pr-review")
    location = finding_location(finding)

    [agent, location, title]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(": ")
  end

  defp finding_location(finding) do
    case {Map.get(finding, "file"), Map.get(finding, "line")} do
      {file, line} when is_binary(file) and is_integer(line) -> "#{file}:#{line}"
      {file, _} when is_binary(file) -> file
      _ -> ""
    end
  end

  defp string_field(map, key, fallback) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> fallback
    end
  end
end
