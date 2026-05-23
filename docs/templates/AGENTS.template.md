# <REPO> — AGENTS.md

Agent cheatsheet for `<org>/<repo>`. Symphony reads this file on turn
1 before any code. If a tracker ticket conflicts with anything here,
this file wins.

Fill in every `<PLACEHOLDER>` block. Delete the
`<!-- INSTRUCTION -->` comments before committing. The schools-out
reference is at `schoolsoutapp/schools-out/AGENTS.md` if you want a
worked example.

## Rule Enforcement Map

Every rule below carries either `[enforced-by: <mechanism>]` (a CI
job, PreToolUse hook, GitHub setting, or Symphony orchestrator gate
halts on violation) or `[advisory]` (prose-only; honor system). Per
SYM-1e, no silent Layer-B rules — every new rule must get one tag.

| Rule | Enforcement |
|------|-------------|
| Turn-1 `## AC Extracted` (or `## BLOCKED: AC not testable`) header | enforced-by: `SymphonyElixir.Orchestrator.GateCEnforcement` |
| `understanding.md` `## Plan` heading + path resolution | enforced-by: `SymphonyElixir.Orchestrator.PlanGroundingGate` |
| Final turn — `## AC Evidence` block with file:line per AC | enforced-by: `SymphonyElixir.GateDValidator` |
| Conflict disclosure — diffs outside `## Files (allowed)` flagged in `## Root cause` | enforced-by: `SymphonyElixir.ConflictDisclosure` + `WorkpadPrSync` |
| Branch naming matches `<TYPE>/<TEAM_KEY>-<N>[-slug]` | enforced-by: PreToolUse `branch_name_check` hook |
| QA self-review on view-layer diffs (`## QA self-review` + `Result: PASS\|BLOCKED`) | enforced-by: `qa-evidence` gate in CI |
| Push to protected branches | enforced-by: GitHub branch protections |
<!-- Add one row per stack-specific rule below. Choose enforced-by or advisory explicitly. -->

For every `[advisory]` rule: residual risk is accepted because either
(a) no obvious automated check exists yet, or (b) the rule is meant
to shape prompt context, not halt the run. New rules MUST add a row
here and choose a tag — no silent rules.

## Stack

<!-- Language, framework, package manager, test runner, lint tools. -->
<!-- Example:
- Language: <Ruby 3.4 / Node 20 / Python 3.12>
- Framework: <Rails 8.0 / Next.js 14 / Django 5.0>
- Tests: <RSpec / Jest / pytest>
- Lint: <rubocop / eslint + prettier / ruff>
- DB: <PostgreSQL / SQLite / none>
-->

## Commands

<!-- Concrete shell commands the agent will invoke at runtime.
     Match what is available in the Docker image (Step 1 of onboarding). -->
- Install: <INSTALL_COMMAND>
- Test all: <TEST_COMMAND>
- Test one file: <SINGLE_TEST_COMMAND>
- Lint: <LINT_COMMAND>
- Server: <DEV_SERVER_COMMAND>

Run lint + tests before every commit. CI enforces both.

## Hard rules [advisory unless tagged otherwise]

<!-- Project-specific conventions that diverge from framework defaults
     and have bitten autonomous agents in the past. Be concrete.
     Example pattern: -->
<!-- - **<RULE>.** <Why it matters and what to do instead.> -->

## PR conventions [mixed — see Rule Enforcement Map]

- Branch from `<DEFAULT_BRANCH>`, PR target `<DEFAULT_BRANCH>`. Never
  PR to a protected release branch directly.
- Branch name pattern: `<TYPE>/<TEAM_KEY>-<N>[-short-slug]`. Symphony
  blocks `git push` on off-pattern names.
- PR title: `[<TEAM_KEY>-<N>] <one-line summary>`.
- PR body: 2–4 sentence summary + `Linear: <issue url>`. Symphony's
  PR template lives at `.github/PULL_REQUEST_TEMPLATE.md` — match its
  required headings (`#### Context / TL;DR / Summary / Alternatives /
  Test Plan`).
- Apply label `symphony` (the orchestrator routes by it).
- Never call `gh pr merge`. Humans merge.

## Symphony agent workflow

When Symphony dispatches you on a tracker-labelled ticket, follow this
process in addition to the codebase conventions above.

### Step 0 — Read repo conventions (mandatory, before any code) [advisory]

Before writing `understanding.md`, before any `Edit` / `Write`, before
branching: read every repo-level instruction file in the workspace.
These override framework defaults and any phrasing in the ticket
description.

Run at turn 1, for each repo you may touch (root and any subdir the
ticket targets):

```
cat AGENTS.md 2>/dev/null
cat CLAUDE.md 2>/dev/null
ls AGENTS.md CLAUDE.md 2>/dev/null
```

For every file path the ticket asks you to **create**, first run
`ls` on it. If the file already exists, you **extend** it; you do
not recreate it under a different name.

Precedence, highest first:

1. Repo `AGENTS.md` / `CLAUDE.md` (closest to the file you edit wins).
2. The workflow definition (`WORKFLOW.<project>.md` in Symphony).
3. The tracker ticket description.
4. Framework defaults.

### Turn-1 workpad post: AC Extracted [enforced-by: orchestrator GateCEnforcement]

Your very first turn-end message — the one Symphony posts to the
tracker workpad — must be a numbered breakdown of acceptance criteria
in this exact format:

```
## AC Extracted

1. <binary pass/fail statement>
2. ...
```

Every item must be testable without subjective interpretation. If the
issue contains a soft requirement that cannot be reduced to a binary
statement ("improve UX", "make it better"), post instead:

```
## BLOCKED: AC not testable

The following items cannot be expressed as binary pass/fail:
- "<verbatim quote from the issue>"

Suggested rewrites:
- "<soft phrase>" → "<concrete binary version>"

Needs PM rewrite before this ticket is workable.
```

After a BLOCKED post, stop calling tools for the rest of the turn.
Symphony re-dispatches on the next poll if the description is fixed.

### Turn-1 deliverable: understanding.md [enforced-by: PlanGroundingGate for `## Plan`; sections 1–4 advisory]

Before any `Edit` / `Write` / mutating `Bash` call, write
`state/<session>/understanding.md` with five sections:

1. **target_repos** — which whitelisted repo(s) the fix touches, with
   a `path/to/file.ext:line` citation per claim.
2. **root_cause** — what is wrong and where, every claim citing a
   file:line. No "I think" / "probably" / "might."
3. **expected_behavior_diff** — smallest possible change. List each
   numbered AC (`AC#1`, `AC#2`, …) → file(s) you will change.
4. **visual_wiring** — required when any AC contains words like
   "renders", "displays", "shows", "visible", "appears", or a UI
   location. For each such AC: name the component (file:line) AND
   the layout/page that mounts it (verified by `grep`).
5. **plan** — under a literal `## Plan` heading: one target file per
   line as a backtick-quoted, workspace-relative path. Tag files
   the plan will create with `(new)`. At least one untagged path
   must resolve to a real file.

Symphony machine-checks the `## Plan` section on turn 1. A missing
heading, a cited path that does not resolve, or an all-`(new)` plan
halts the run.

### Operating rules

<!-- Project-specific rules go here. The canonical pattern is:
     numbered list, each entry one rule with a bolded headline,
     followed by a short explanation. Tag each rule [enforced-by] or
     [advisory] inline. -->

1. **AC-trace mandatory.** Every changed file maps to a numbered AC
   item from the issue description. PR body lists
   `AC#N → file.ext:line-range` for each AC.

2. **No-drive-by edits.** Default: inline new logic into the
   existing caller. Extract to a service / module only when call
   site #2 already exists in the same diff. No quote-style swaps,
   no spontaneous docstrings, no whitespace reformat outside the
   diff scope.

3. **One atomic commit per logical change.** Concise descriptive
   messages.

4. **Quality gates before pushing.** Run lint + tests for every file
   you touched. Both must exit 0 before `git push`.

### Hard stops

- Do not modify paths outside the cloned workspace.
- Do not push to protected branches directly. Always go through a
  PR.
- Do not bypass branch protections, CI, or `--no-verify` git hooks.
- Do not clone any repo not in the workflow's "Allowed repositories"
  whitelist.
- Do not run `Edit` / `Write` before `state/<session>/understanding.md`
  exists with all five sections populated.
- If auth / permissions / tooling feels off (token errors, repo not
  found), stop. Do not retry blindly.

### Final turn [enforced-by: GateDValidator on `## AC Evidence`]

When you finish a clean PR, end your turn with the two sections
below in order, then stop calling tools.

**1 — AC Evidence (required)**

Map every acceptance criterion from your turn-1 `## AC Extracted`
post to the specific file, line, or test that satisfies it:

```
## AC Evidence

- AC 1 — <criterion text>: `path/to/file.ext:42` (`relevant_symbol`)
- AC 2 — <criterion text>: `spec/.../foo_spec.rb:88` (example `"description"`)
```

If the session ended blocked, use `## BLOCKED: <reason>` instead.
`GateDValidator` rejects PRs that claim AC "verified" without a
resolvable file:line.

**2 — Summary**

Short summary with the PR URL and `git diff --stat <DEFAULT_BRANCH>..HEAD`.
Do not call any tracker API yourself — Symphony moves the issue state
and posts the workpad based on your final message.
