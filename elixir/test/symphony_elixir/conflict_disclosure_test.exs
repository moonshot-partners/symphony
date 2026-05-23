defmodule SymphonyElixir.ConflictDisclosureTest do
  @moduledoc """
  Unit coverage for `SymphonyElixir.ConflictDisclosure`.

  Pure decision boundary: given the ticket description, the PR's changed
  files, and the agent's `understanding.md`, decides whether every
  off-allowlist file was disclosed in the `## Root cause` section.

  SYM-30 (AC4 of SYM-1).
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.ConflictDisclosure

  describe "parse_allowed_files/1" do
    test "returns empty list for nil and empty" do
      assert ConflictDisclosure.parse_allowed_files(nil) == []
      assert ConflictDisclosure.parse_allowed_files("") == []
    end

    test "returns empty list when no ## Files (allowed) header present" do
      assert ConflictDisclosure.parse_allowed_files("## Summary\n\nbody") == []
    end

    test "extracts single backtick-quoted path from bullet" do
      text = """
      ## Files (allowed)

      - `lib/foo.ex`
      """

      assert ConflictDisclosure.parse_allowed_files(text) == ["lib/foo.ex"]
    end

    test "extracts multiple paths from bullet list" do
      text = """
      ## Files (allowed)

      - `lib/foo.ex`
      - `test/foo_test.exs`
      - `priv/templates/foo.eex`
      """

      assert ConflictDisclosure.parse_allowed_files(text) ==
               ["lib/foo.ex", "test/foo_test.exs", "priv/templates/foo.eex"]
    end

    test "ignores non-path backtick tokens (method names, prose)" do
      text = """
      ## Files (allowed)

      - `lib/foo.ex` — call `do_work/1` only
      - `bar` is just prose
      """

      assert ConflictDisclosure.parse_allowed_files(text) == ["lib/foo.ex"]
    end

    test "stops at the next H2 header" do
      text = """
      ## Files (allowed)

      - `lib/foo.ex`

      ## Other Section

      - `lib/should_ignore.ex`
      """

      assert ConflictDisclosure.parse_allowed_files(text) == ["lib/foo.ex"]
    end

    test "is case-insensitive on the header" do
      text = """
      ## files (Allowed)

      - `lib/foo.ex`
      """

      assert ConflictDisclosure.parse_allowed_files(text) == ["lib/foo.ex"]
    end

    test "dedupes when a path appears twice" do
      text = """
      ## Files (allowed)

      - `lib/foo.ex`
      - `lib/foo.ex`
      """

      assert ConflictDisclosure.parse_allowed_files(text) == ["lib/foo.ex"]
    end
  end

  describe "disclosed?/2" do
    test "returns true when the path appears verbatim in the root cause text" do
      text = """
      ## Root cause

      Had to extract `lib/extra.ex` to satisfy the 600-line split.
      """

      assert ConflictDisclosure.disclosed?(text, "lib/extra.ex") == true
    end

    test "returns true when the path appears without backticks" do
      text = """
      ## Root cause

      Touched lib/extra.ex for concern extraction.
      """

      assert ConflictDisclosure.disclosed?(text, "lib/extra.ex") == true
    end

    test "returns false when the path is not mentioned" do
      text = """
      ## Root cause

      Just renamed a variable in lib/main.ex.
      """

      assert ConflictDisclosure.disclosed?(text, "lib/extra.ex") == false
    end

    test "returns false when the text is nil or empty" do
      assert ConflictDisclosure.disclosed?(nil, "lib/extra.ex") == false
      assert ConflictDisclosure.disclosed?("", "lib/extra.ex") == false
    end

    test "ignores prose outside the ## Root cause section" do
      text = """
      ## Summary

      We touched lib/extra.ex.

      ## Plan

      - `lib/main.ex`
      """

      # No `## Root cause` section at all -> not disclosed.
      assert ConflictDisclosure.disclosed?(text, "lib/extra.ex") == false
    end

    test "matches case-insensitively on the section header" do
      text = """
      ## root cause

      Extracted lib/extra.ex.
      """

      assert ConflictDisclosure.disclosed?(text, "lib/extra.ex") == true
    end
  end

  describe "validate/3" do
    test "returns :ok when description carries no allowlist (gate is a no-op)" do
      assert ConflictDisclosure.validate("## Summary\n\nbody", ["lib/a.ex", "lib/b.ex"], nil) ==
               :ok
    end

    test "returns :ok when description is nil" do
      assert ConflictDisclosure.validate(nil, ["lib/a.ex"], nil) == :ok
    end

    test "returns :ok when the diff is fully inside the allowlist" do
      description = """
      ## Files (allowed)

      - `lib/a.ex`
      - `lib/b.ex`
      """

      assert ConflictDisclosure.validate(description, ["lib/a.ex", "lib/b.ex"], nil) == :ok
    end

    test "returns :ok when off-allowlist files are disclosed in root cause" do
      description = """
      ## Files (allowed)

      - `lib/a.ex`
      - `lib/b.ex`
      """

      understanding = """
      ## Plan

      - `lib/a.ex`

      ## Root cause

      Also touched lib/c.ex for concern extraction (was at 600 lines).
      """

      assert ConflictDisclosure.validate(
               description,
               ["lib/a.ex", "lib/b.ex", "lib/c.ex"],
               understanding
             ) == :ok
    end

    test "returns {:fail, extras} when off-allowlist files are not disclosed" do
      description = """
      ## Files (allowed)

      - `lib/a.ex`
      - `lib/b.ex`
      """

      understanding = """
      ## Plan

      - `lib/a.ex`
      """

      assert ConflictDisclosure.validate(
               description,
               ["lib/a.ex", "lib/b.ex", "lib/c.ex"],
               understanding
             ) == {:fail, ["lib/c.ex"]}
    end

    test "collects every undisclosed extra, not just the first" do
      description = """
      ## Files (allowed)

      - `lib/a.ex`
      """

      understanding = """
      ## Root cause

      Touched lib/c.ex deliberately.
      """

      assert ConflictDisclosure.validate(
               description,
               ["lib/a.ex", "lib/b.ex", "lib/c.ex", "lib/d.ex"],
               understanding
             ) == {:fail, ["lib/b.ex", "lib/d.ex"]}
    end

    test "treats nil understanding_md as 'nothing disclosed' when extras exist" do
      description = """
      ## Files (allowed)

      - `lib/a.ex`
      """

      assert ConflictDisclosure.validate(
               description,
               ["lib/a.ex", "lib/b.ex"],
               nil
             ) == {:fail, ["lib/b.ex"]}
    end

    test "returns :ok when changed_files is empty (nothing to check)" do
      description = """
      ## Files (allowed)

      - `lib/a.ex`
      """

      assert ConflictDisclosure.validate(description, [], nil) == :ok
    end

    test "SODEV-930 replay: 4-file backend diff vs 2-file allowlist, no disclosure -> fail" do
      description = """
      ## Files (allowed)

      - `app/models/user.rb`
      - `spec/models/user_spec.rb`
      """

      changed_files = [
        "app/models/user.rb",
        "spec/models/user_spec.rb",
        "app/controllers/users_controller.rb",
        "config/routes.rb"
      ]

      # No understanding.md -> all extras undisclosed.
      assert ConflictDisclosure.validate(description, changed_files, nil) ==
               {:fail, ["app/controllers/users_controller.rb", "config/routes.rb"]}
    end
  end
end
