defmodule SymphonyElixir.QaArtifactGate do
  @moduledoc """
  QA artifact substance check — when an agent's PR body claims
  `- Result: PASS` under the `## QA self-review` section, or the ticket/PR
  contract describes visual UI behavior, verify a real qa-evidence artifact
  (screenshot/webm/zip) exists on disk before the orchestrator routes the
  ticket to `on_complete_state`.

  SYM-34 closes the gap surfaced on SODEV-892 (2026-05-23): the fe-next-app
  CI gate (`qa-evidence` workflow in fe-next-app PR #519/#521) only checks
  for the literal `## QA self-review` heading + `- Result: PASS|BLOCKED`
  line in the PR body. The agent can satisfy that check by writing prose
  while skipping the Playwright run entirely.

  Pure boundary so the rule can be exercised in isolation.
  `Orchestrator.WorkpadPrSync` wires it into the `pr_attached` routing
  alongside `GateDValidator` and `ConflictDisclosure`.

  ## The contract

    * If the PR body has no `- Result: PASS` line and the ticket/PR does not
      describe visual UI behavior → `:ok` (other routes handle FAIL / BLOCKED /
      missing-section).
    * If it does, or the ticket/PR describes visual UI behavior, look for at
      least one non-empty artifact file in:
      - the staged snapshot at `/tmp/symphony-qa-staged-<issue_id>` (the
        retry-survival dir written by `QaEvidence.stage_pending_publish/2`),
        OR
      - one of `<workspace_path>/<subpath>` for each configured qa
        evidence subpath (defaults to `fe-next-app/qa-evidence` +
        `qa-evidence`).
    * Artifact extensions: `.png .jpg .jpeg .gif .webm .mp4 .zip`.
      `qa-report.md` alone does not satisfy — it is the agent's prose
      report, the gate is for runtime proof.
    * Zero artifacts found → `{:fail, :no_artifact}`.
  """

  @type result :: :ok | {:fail, :no_artifact}

  @default_subpaths ["fe-next-app/qa-evidence", "qa-evidence"]
  @artifact_exts ~w(.png .jpg .jpeg .gif .webm .mp4 .zip)

  @pass_pattern ~r/^[\s-]*Result:\s*PASS\b/m
  @visual_contract_pattern ~r/\b(badge|button|cta|displays?|renders?|screens?|screenshots?|shows?|visible|visual|page|tab|modal|dialog|component|layout|header|footer|sidebar)\b/i

  @doc """
  Returns true when the PR body claims a passing QA self-review.
  Match is anchored on a `- Result: PASS` line (the format enforced by
  the fe-next-app qa-evidence CI gate).
  """
  @spec claims_pass?(String.t() | nil) :: boolean()
  def claims_pass?(nil), do: false
  def claims_pass?(body) when is_binary(body), do: Regex.match?(@pass_pattern, body)

  @doc """
  Validate the PR body against the agent's workspace + staged evidence
  directory. Returns `:ok` when neither the PR body nor the ticket contract
  requires runtime visual proof, or when a real artifact file is found.
  Returns `{:fail, :no_artifact}` when visual proof is required but missing.

  `opts`:
    * `:subpaths` — overrides the qa evidence subpath list (defaults to
      `["fe-next-app/qa-evidence", "qa-evidence"]`). The caller normally
      passes `SymphonyElixir.Config.qa_evidence_subpaths/0` so the gate
      tracks the active workflow.
    * `:changed_files` — when present, root-level Markdown-only PRs do not
      require runtime QA artifacts.
    * `:issue_description` — ticket text used to detect visual UI acceptance
      criteria even when the PR body claims QA is not required.
  """
  @spec validate(String.t() | nil, String.t() | nil, String.t() | nil, keyword()) :: result()
  def validate(body, workspace_path, issue_id, opts \\ []) do
    cond do
      not qa_artifact_required?(body, Keyword.get(opts, :issue_description)) ->
        :ok

      root_markdown_only?(Keyword.get(opts, :changed_files, [])) ->
        :ok

      true ->
        subpaths = Keyword.get(opts, :subpaths, @default_subpaths)
        check_artifacts(workspace_path, issue_id, subpaths)
    end
  end

  @doc """
  Returns true when the PR body or ticket contract requires runtime visual
  evidence. A `- Result: PASS` claim always requires artifacts; visual UI
  language also requires artifacts even when the PR body says QA was not
  required.
  """
  @spec qa_artifact_required?(String.t() | nil, String.t() | nil) :: boolean()
  def qa_artifact_required?(body, issue_description \\ nil) do
    claims_pass?(body) or visual_contract?(body) or visual_contract?(issue_description)
  end

  @spec visual_contract?(String.t() | nil) :: boolean()
  def visual_contract?(nil), do: false
  def visual_contract?(text) when is_binary(text), do: Regex.match?(@visual_contract_pattern, text)

  defp root_markdown_only?([]), do: false

  defp root_markdown_only?(files) when is_list(files) do
    Enum.all?(files, &root_markdown?/1)
  end

  defp root_markdown_only?(_), do: false

  defp root_markdown?(path) when is_binary(path) do
    Path.dirname(path) == "." and String.downcase(Path.extname(path)) in [".md", ".markdown"]
  end

  defp root_markdown?(_), do: false

  defp check_artifacts(workspace_path, issue_id, subpaths) do
    dirs = candidate_dirs(workspace_path, issue_id, subpaths)

    if Enum.any?(dirs, &dir_has_artifact?/1) do
      :ok
    else
      {:fail, :no_artifact}
    end
  end

  defp candidate_dirs(workspace_path, issue_id, subpaths) do
    staged =
      if is_binary(issue_id) and issue_id != "" do
        [Path.join(System.tmp_dir!(), "symphony-qa-staged-#{issue_id}")]
      else
        []
      end

    workspaces =
      if is_binary(workspace_path) and workspace_path != "" do
        Enum.map(subpaths, &Path.join(workspace_path, &1))
      else
        []
      end

    staged ++ workspaces
  end

  defp dir_has_artifact?(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.any?(names, fn name -> artifact_file?(Path.join(dir, name)) end)

      _ ->
        false
    end
  end

  defp artifact_file?(path) do
    ext = path |> Path.extname() |> String.downcase()

    if ext in @artifact_exts do
      non_empty_regular?(path)
    else
      false
    end
  end

  defp non_empty_regular?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end
end
