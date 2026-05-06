---
tracker:
  kind: linear
  project_slug: "c2bd55c135ce"
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Scheduled
    - In Development
    - In QA / Review
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    if [ -z "$SYMPHONY_TARGET_REPO_URL" ]; then
      echo "after_create: SYMPHONY_TARGET_REPO_URL is not set" >&2
      exit 1
    fi
    git clone --depth 1 "$SYMPHONY_TARGET_REPO_URL" .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get && cd ..
    fi
    mkdir -p .git/hooks
    cat > .git/hooks/pre-commit <<'PRECOMMIT_EOF'
    #!/bin/sh
    # Symphony pre-commit quality gate.
    # Bypass with SYMPHONY_DISABLE_PRECOMMIT=1 only for local debugging.
    set -e
    [ "${SYMPHONY_DISABLE_PRECOMMIT:-0}" = "1" ] && exit 0

    if command -v mise >/dev/null 2>&1; then
      MIX="mise exec -- mix"
    elif command -v mix >/dev/null 2>&1; then
      MIX="mix"
    else
      echo "pre-commit: neither mise nor mix found; skipping format check." >&2
      exit 0
    fi

    # Symphony-style monorepo (elixir/ subdir).
    if [ -f elixir/.formatter.exs ]; then
      staged=$(git diff --cached --name-only --diff-filter=ACM \
        | grep -E '^elixir/.*\.(ex|exs)$' \
        | grep -v '^elixir/\.formatter\.exs$' \
        || true)
      if [ -n "$staged" ]; then
        rel=$(echo "$staged" | sed 's|^elixir/||')
        (cd elixir && $MIX format --check-formatted $rel) || {
          echo "pre-commit: mix format failed. Run: cd elixir && $MIX format $rel" >&2
          exit 1
        }
      fi
    fi

    # Flat Elixir layout.
    if [ -f .formatter.exs ]; then
      staged=$(git diff --cached --name-only --diff-filter=ACM \
        | grep -E '\.(ex|exs)$' \
        | grep -v '^\.formatter\.exs$' \
        || true)
      if [ -n "$staged" ]; then
        $MIX format --check-formatted $staged || {
          echo "pre-commit: mix format failed. Run: $MIX format $staged" >&2
          exit 1
        }
      fi
    fi

    exit 0
    PRECOMMIT_EOF
    chmod +x .git/hooks/pre-commit
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
agent_runtime:
  # Default agent backend = Python shim around claude-agent-sdk.
  # See priv/agent_shim/README.md for setup (uv sync) and ANTHROPIC_OAUTH_TOKEN config.
  command: $SYMPHONY_AGENT_SHIM_PYTHON -m symphony_agent_shim
  approval_policy: never
  thread_sandbox: workspace-write
  read_timeout_ms: 120000
  turn_sandbox_policy:
    type: workspaceWrite
server:
  host: 127.0.0.1
  port: 4000
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be assigned
  to the same project as the current issue, link the current issue as `related`,
  and use `blockedBy` when the follow-up depends on the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Quality Gates (mandatory)

These rules are non-negotiable for every implementation step. They are enforced both by the workspace pre-commit hook and by reviewer expectation.

- TDD cycle: write failing test first (RED), implement minimum to pass (GREEN), refactor without breaking (REFACTOR), commit per behavior. Skip TDD only for pure config/docs/infra changes.
- Atomic commits: one behavior per commit, descriptive subject, never mix unrelated changes in the same commit.
- File length budget: warn at >400 lines, mandatory split at >600 lines. When a file under edit exceeds 600 lines, split before adding new logic.
- No silent TODOs: every TODO in code must reference an open Linear issue. If you would write a TODO without an issue, file the follow-up issue first (same project, `related` link to current).
- Verification before push: run lint and the full test suite for the touched scope. If lint or tests fail, fix or revert before pushing. Never bypass with `--no-verify`.
- Pre-commit hook: the workspace ships with a `.git/hooks/pre-commit` that runs `mix format --check-formatted` on staged Elixir files. Do not delete or skip it. `SYMPHONY_DISABLE_PRECOMMIT=1` is for emergency local debugging only, never for pushed commits.
- Over-abstraction (Karpathy rule): do not introduce an interface or abstract class for a single concrete implementation. Prefer the concrete type until a second use case forces the abstraction.
- Drive-by refactors: do not rename, reformat, or rewrite code outside the scope of the current ticket. Out-of-scope improvements go to a separate follow-up issue, not into the current diff.
- Frontend changes: prioritize visual silence and low cognitive load. Reuse design tokens. WCAG AA contrast minimum. Replace default browser focus rings with custom states.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.

## Status map

- `Scheduled` -> queued; immediately transition to `In Development` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `In QA / Review`).
- `In Development` -> implementation actively underway.
- `In QA / Review` -> PR is attached and validated; waiting on human approval. Agent stops editing and polls for review feedback. When the reviewer requests changes, the reviewer manually moves the issue back to `In Development` to re-enter agent execution.
- `Released / Live`, `Closed`, `Canceled`, `Duplicate` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Scheduled` -> immediately move to `In Development`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Development` -> continue execution flow from current scratchpad comment.
   - `In QA / Review` -> wait and poll for decision/review updates.
   - terminal (`Released / Live`, `Closed`, `Canceled`, `Duplicate`) -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Scheduled` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Development")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Scheduled or In Development)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Scheduled`, do not delay on additional status transitions: the issue should already be `In Development` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `In QA / Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `In QA / Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `In QA / Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Scheduled -> In Development -> In QA / Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Scheduled`, move it to `In Development`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Scheduled` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `In QA / Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `In QA / Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `In QA / Review` with the blocker brief and explicit unblock actions.
13. For `Scheduled` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `In QA / Review`.

## Step 3: In QA / Review handling

1. When the issue is in `In QA / Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, the reviewer manually moves the issue back to `In Development`. On re-entry, treat the run as a full approach reset:
   - Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
   - Update the existing `## Codex Workpad` comment with the revised plan and continue from there.
4. When the human approves the PR and merges it, the human transitions the issue to a terminal state (`Released / Live` or `Closed`). The agent does not perform the merge itself.

## Completion bar before In QA / Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate follow-up issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `In QA / Review` unless the `Completion bar before In QA / Review` is satisfied.
- In `In QA / Review`, do not make changes; wait and poll.
- If state is terminal (`Released / Live`, `Closed`, `Canceled`, `Duplicate`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
