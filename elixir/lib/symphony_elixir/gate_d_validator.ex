defmodule SymphonyElixir.GateDValidator do
  @moduledoc """
  Gate D Validator — substance verification for the agent's `## AC Evidence`
  section. Promotes Gate D from header-presence check (covered by
  `SymphonyElixir.GateDObserver`) to claim-by-claim verification.

  ## Decision

  Each parsed entry has a status:

    * `:verified` (keywords `verified` / `passed` / `green` / `ok`) — must
      cite at least one *resolvable* artifact reference.
    * `:skipped` / `:blocked` — explicit non-claims; require nothing.
    * `:malformed` — no recognizable status keyword; not a hard fail (the
      agent did not claim verification, so there is nothing to refute).
      Observability lives in the parser output, not in `validate/2`.

  ## Resolution

  An artifact ref is resolvable if it is:

    * an http(s) URL — treated as `:ok` here (CI run cross-check is a
      deferred follow-up, kept out of scope to ship the substance check now).
    * a workspace-relative file path (with optional `:line` suffix) that
      exists and is non-empty when `workspace_path` is provided. For
      multi-repo workspaces, bare filenames are also checked one directory
      below the workspace root so repo-root command evidence like
      `test "$(cat SENTINEL.md)" = ...` can resolve when the checkout lives in
      `<workspace_path>/<repo>/SENTINEL.md`.

  Injection point for tests: `:gate_d_ref_resolver_fn` (same shape as the
  `:pr_ready_fn` / `:pr_qa_blocked_fn` / `:pr_required_checks_status_fn`
  knobs on `SymphonyElixir.GitHubPr`).
  """

  @type claim_status :: :verified | :skipped | :blocked | :malformed

  @type claim :: %{
          ac_id: String.t(),
          status: claim_status(),
          body: String.t(),
          refs: [String.t()]
        }

  @type ctx :: %{optional(:workspace_path) => String.t() | nil}

  @type failure :: %{ac_id: String.t(), reason: :unbacked | :no_resolvable_ref}

  @type result :: :ok | {:fail, [failure()]}

  @verified_keywords ~w(verified passed passes passing green ok covers covered)
  @skipped_keywords ~w(skipped n/a deferred unrun)
  @blocked_keywords ~w(blocked)

  @section_pattern ~r/^##[ \t]+AC Evidence\b.*?(?=^##[ \t]|\z)/ms
  @entry_pattern ~r/(?:^|\n)\s*(?:[-*]\s+)?AC[\s#]*?(\d+)(?:\s*[:\-–>]+\s*|\s+)(.+?)(?=\n\s*(?:[-*]\s+)?AC[\s#]*?\d+|\z)/is
  @url_pattern Regex.compile!("https?://[^\\s,)\\]]+")
  @path_pattern Regex.compile!("[\\w./-]+\\.[A-Za-z]{1,6}(?::\\d+)?")

  @doc """
  Parse the section under `## AC Evidence` into `[claim()]`. Returns
  `[]` for nil / empty / no-header input.
  """
  @spec parse_ac_evidence_section(String.t() | nil) :: [claim()]
  def parse_ac_evidence_section(nil), do: []
  def parse_ac_evidence_section(""), do: []

  def parse_ac_evidence_section(text) when is_binary(text) do
    case Regex.run(@section_pattern, text) do
      nil ->
        []

      [section] ->
        section
        |> strip_header()
        |> extract_entries()
    end
  end

  defp strip_header(section) do
    section
    |> String.replace(~r/^##[ \t]+AC Evidence\b[^\n]*\n?/m, "", global: false)
    |> String.trim()
  end

  defp extract_entries(""), do: []

  defp extract_entries(body) do
    @entry_pattern
    |> Regex.scan(body)
    |> Enum.map(fn [_full, ac_id, rest] ->
      trimmed = String.trim(rest)

      %{
        ac_id: ac_id,
        status: classify_status(trimmed),
        body: trimmed,
        refs: extract_refs(trimmed)
      }
    end)
  end

  defp classify_status(body) do
    lower = String.downcase(body)

    cond do
      Enum.any?(@verified_keywords, &word_present?(lower, &1)) -> :verified
      Enum.any?(@blocked_keywords, &word_present?(lower, &1)) -> :blocked
      Enum.any?(@skipped_keywords, &word_present?(lower, &1)) -> :skipped
      true -> :malformed
    end
  end

  defp word_present?(text, "n/a"), do: String.contains?(text, "n/a")

  defp word_present?(text, keyword) do
    Regex.match?(~r/\b#{Regex.escape(keyword)}\b/, text)
  end

  defp extract_refs(body) do
    urls = Regex.scan(@url_pattern, body) |> Enum.map(&hd/1)

    paths =
      @path_pattern
      |> Regex.scan(body)
      |> Enum.map(&hd/1)
      |> Enum.reject(&String.starts_with?(&1, ["http://", "https://"]))

    Enum.uniq(urls ++ paths)
  end

  @doc """
  Validate the full final-turn text. Returns `:ok` when every
  `verified` claim has at least one resolvable artifact ref, or
  `{:fail, [failure()]}` listing the offending AC IDs.
  """
  @spec validate(String.t() | nil, ctx()) :: result()
  def validate(text, ctx) do
    case parse_ac_evidence_section(text) do
      [] ->
        :ok

      claims ->
        case Enum.flat_map(claims, &check_claim(&1, ctx)) do
          [] -> :ok
          failures -> {:fail, failures}
        end
    end
  end

  defp check_claim(%{status: status}, _ctx) when status in [:skipped, :blocked, :malformed], do: []

  defp check_claim(%{status: :verified, refs: [], ac_id: id}, _ctx) do
    [%{ac_id: id, reason: :unbacked}]
  end

  defp check_claim(%{status: :verified, refs: refs, ac_id: id}, ctx) do
    resolver = Application.get_env(:symphony_elixir, :gate_d_ref_resolver_fn, &__MODULE__.default_ref_resolver/2)

    if Enum.any?(refs, fn ref -> resolver.(ref, ctx) == :ok end) do
      []
    else
      [%{ac_id: id, reason: :no_resolvable_ref}]
    end
  end

  @doc """
  Default artifact ref resolver. Treats http(s) URLs as `:ok`
  (defers CI cross-check); checks workspace files for existence +
  non-empty content.
  """
  @spec default_ref_resolver(String.t(), ctx()) :: :ok | {:error, atom()}
  def default_ref_resolver("http://" <> _, _ctx), do: :ok
  def default_ref_resolver("https://" <> _, _ctx), do: :ok

  def default_ref_resolver(ref, ctx) when is_binary(ref) do
    case Map.get(ctx, :workspace_path) do
      nil -> {:error, :no_workspace}
      ws when is_binary(ws) -> resolve_file_ref(ref, ws)
    end
  end

  defp resolve_file_ref(ref, workspace_path) do
    ref
    |> candidate_paths(workspace_path)
    |> Enum.reduce_while({:error, :missing}, fn path, _last_error ->
      case check_file(path) do
        :ok -> {:halt, :ok}
        error -> {:cont, error}
      end
    end)
  end

  defp strip_line_suffix(ref) do
    case Regex.run(~r/^(.+?):\d+$/, ref) do
      [_full, path] -> path
      _ -> ref
    end
  end

  defp candidate_paths(ref, workspace_path) do
    path = strip_line_suffix(ref)
    direct = Path.join(workspace_path, path)

    nested =
      if bare_filename?(path) do
        Path.wildcard(Path.join([workspace_path, "*", path]))
      else
        []
      end

    Enum.uniq([direct | nested])
  end

  defp bare_filename?(path) do
    Path.split(path) == [path]
  end

  defp check_file(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} -> {:error, :empty}
      {:ok, %{type: :regular}} -> :ok
      {:ok, _} -> {:error, :not_regular}
      {:error, _} -> {:error, :missing}
    end
  end
end
