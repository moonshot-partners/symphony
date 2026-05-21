defmodule SymphonyElixir.PlanGrounding do
  @moduledoc """
  Plan-grounding check — validates that the agent's turn-1 `## Plan` section
  in `understanding.md` names real target files in the workspace.

  Symphony's discovery contract already asks the agent to write
  `understanding.md` with citation-backed sections. Nothing on the Symphony
  side ever verified those citations, so an agent could name a plausible-but
  -wrong file and proceed — shipping correct code in the wrong place
  ("filter by kid"). This is the machine check that closes that gap.

  Pure boundary so the orchestrator stays workflow-agnostic and the rule can
  be exercised in isolation. `Orchestrator.PlanGroundingGate` wires it into
  the turn loop and acts on a violation.

  ## The contract

  Turn-1 `understanding.md` must carry a `## Plan` section listing each
  target file as a backtick-quoted, workspace-relative path. A file the plan
  will create (not yet on disk) is tagged `(new)` on its line.

  A plan is **grounded** when:

    * the `## Plan` section exists,
    * every untagged path resolves to a real file under the workspace, and
    * at least one untagged path resolves — a plan made entirely of `(new)`
      files is not anchored in the real codebase.

  Only the first path-like backtick token per line is treated as the line's
  target file; later backtick tokens (method names, shell commands, prose
  references) are ignored. A token is path-like when, after stripping a
  trailing `:line` citation, it ends in a file extension.
  """

  @typedoc "Outcome of a plan-grounding validation."
  @type result ::
          :ok
          | {:violation, :missing_plan_section}
          | {:violation, :no_grounded_path}
          | {:violation, {:path_not_found, [String.t()]}}

  # `## Plan` header, then everything up to the next `## ` header or EOF.
  @plan_section ~r/^##[ \t]+Plan\b.*?(?=^##[ \t]|\z)/ms
  # A backtick-quoted token: `...`.
  @backtick_token ~r/`([^`]+)`/
  # A path-like token: ends in `.ext` after an optional `:line` suffix is removed.
  @path_like ~r/\.[A-Za-z0-9]+$/

  @spec validate(String.t() | nil, String.t()) :: result()
  def validate(understanding_md, workspace_path)
      when is_binary(understanding_md) and is_binary(workspace_path) do
    case extract_plan_section(understanding_md) do
      nil ->
        {:violation, :missing_plan_section}

      section ->
        check_paths(section, workspace_path)
    end
  end

  def validate(_understanding_md, _workspace_path), do: {:violation, :missing_plan_section}

  defp extract_plan_section(text) do
    case Regex.run(@plan_section, text) do
      [section] -> section
      nil -> nil
    end
  end

  defp check_paths(section, workspace_path) do
    {existing, missing} =
      section
      |> String.split("\n")
      |> Enum.flat_map(&path_entry/1)
      |> Enum.split_with(fn {path, _new?} -> resolves?(path, workspace_path) end)

    untagged_missing =
      missing
      |> Enum.reject(fn {_path, new?} -> new? end)
      |> Enum.map(fn {path, _new?} -> path end)
      |> Enum.uniq()

    # Anchor = an untagged path that resolves. A `(new)` tag on a file that
    # happens to exist still does not anchor the plan — the contract asks
    # for a real file the plan is *building on*, not creating.
    grounded_anchor? = Enum.any?(existing, fn {_path, new?} -> not new? end)

    cond do
      untagged_missing != [] -> {:violation, {:path_not_found, untagged_missing}}
      not grounded_anchor? -> {:violation, :no_grounded_path}
      true -> :ok
    end
  end

  # Returns `[{path, new?}]` (0 or 1 element) for a plan line — the first
  # path-like backtick token, paired with whether the line tags it `(new)`.
  defp path_entry(line) do
    new? = line =~ ~r/\(new\)/i

    @backtick_token
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.map(fn [token] -> normalize(token) end)
    |> Enum.find(&path_like?/1)
    |> case do
      nil -> []
      path -> [{path, new?}]
    end
  end

  defp normalize(token) do
    token
    |> String.trim()
    |> String.replace(~r/:\d+$/, "")
    |> String.replace_prefix("./", "")
  end

  defp path_like?(token), do: Regex.match?(@path_like, token)

  defp resolves?(path, workspace_path) do
    File.regular?(Path.join(workspace_path, path))
  end
end
