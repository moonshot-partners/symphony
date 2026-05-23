defmodule SymphonyElixir.ConflictDisclosure do
  @moduledoc """
  Conflict-disclosure machine check — verifies that off-allowlist files in
  the PR diff are explicitly disclosed in `understanding.md`.

  SYM-30 (AC4 of SYM-1).

  When a ticket spec declares a minimal-diff allowlist via a
  `## Files (allowed)` section, `WORKFLOW.schools-out.md` requires the
  agent to note any exception in `understanding.md` under `## Root cause`.
  The note part is prose-only — the agent skipped it on SODEV-930. This
  module is the machine check that closes that gap.

  Pure boundary so the rule can be exercised in isolation.
  `Orchestrator.WorkpadPrSync` wires it into the `pr_attached` routing
  alongside `GateDValidator` substance verification.

  ## The contract

  The ticket description carries an optional `## Files (allowed)`
  section listing each minimum-diff path as a backtick-quoted,
  workspace-relative path. If the section is absent the gate is a no-op
  (no false positives).

  When the section is present:

    * Compute `extras = changed_files - allowed_files`.
    * For each path in `extras`, scan the agent's `## Root cause`
      section in `understanding.md` for a literal mention of that path
      (substring match, case-insensitive).
    * Undisclosed extras → `{:fail, undisclosed_paths}`.
    * All extras disclosed (or no extras) → `:ok`.
  """

  @type result :: :ok | {:fail, [String.t()]}

  @allowed_section ~r/^##[ \t]+Files[ \t]*\(allowed\).*?(?=^##[ \t]|\z)/msi
  @root_cause_section ~r/^##[ \t]+Root[ \t]+cause\b.*?(?=^##[ \t]|\z)/msi
  @backtick_token ~r/`([^`]+)`/
  @path_like ~r/\.[A-Za-z0-9]+$/

  @spec parse_allowed_files(String.t() | nil) :: [String.t()]
  def parse_allowed_files(nil), do: []
  def parse_allowed_files(""), do: []

  def parse_allowed_files(text) when is_binary(text) do
    case Regex.run(@allowed_section, text) do
      nil ->
        []

      [section] ->
        @backtick_token
        |> Regex.scan(section, capture: :all_but_first)
        |> Enum.map(fn [token] -> String.trim(token) end)
        |> Enum.filter(&path_like?/1)
        |> Enum.uniq()
    end
  end

  @spec disclosed?(String.t() | nil, String.t()) :: boolean()
  def disclosed?(nil, _path), do: false
  def disclosed?("", _path), do: false

  def disclosed?(text, path) when is_binary(text) and is_binary(path) do
    case Regex.run(@root_cause_section, text) do
      nil -> false
      [section] -> String.contains?(String.downcase(section), String.downcase(path))
    end
  end

  @spec validate(String.t() | nil, [String.t()], String.t() | nil) :: result()
  def validate(description, changed_files, understanding_md)
      when is_list(changed_files) do
    case parse_allowed_files(description) do
      [] ->
        :ok

      allowed ->
        extras = changed_files -- allowed

        case Enum.reject(extras, &disclosed?(understanding_md, &1)) do
          [] -> :ok
          undisclosed -> {:fail, undisclosed}
        end
    end
  end

  defp path_like?(token), do: Regex.match?(@path_like, token)
end
