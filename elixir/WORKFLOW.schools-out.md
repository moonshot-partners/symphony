---
tracker:
  kind: linear
  team_key: SODEV
  routing_label: agent
  active_states:
    - Scheduled
    - In Development
  terminal_states:
    - Released / Live
    - Closed
    - Canceled
    - Duplicate
  on_pickup_state: "In Development"
  on_complete_state: "In QA / Review"
  on_pr_merge_state: null
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    # Primary repo at workspace root.
    git clone --depth 1 https://github.com/schoolsoutapp/schools-out .
    # Point origin/HEAD → dev so `gh pr create` defaults to dev (not main).
    # Pre-fetch dev so `git checkout -B ... origin/dev` works without extra fetch.
    git remote set-head origin dev
    git fetch --depth=1 origin dev
    # Frontend repo at ./fe-next-app — eliminates the SODEV-827 class of
    # bugs where the agent had to clone the right repo mid-run after
    # burning turns on the wrong one. Whitelist mirrored in the prompt
    # body's "Allowed repositories" section.
    git clone --depth 1 https://github.com/schoolsoutapp/fe-next-app fe-next-app
    # fe-next-app's integration branch is `dev`. The shallow clone only brings
    # `main`, so fetch `dev` explicitly into a real remote-tracking ref BEFORE
    # pointing origin/HEAD at it.
    git -C fe-next-app fetch --depth=1 origin dev:refs/remotes/origin/dev
    git -C fe-next-app remote set-head origin dev
    # fe-next-app is an npm project (versions package-lock.json). Install deps
    # here with `npm ci` — if `pnpm install` runs later it builds a strict
    # node_modules that fails undeclared transitive imports (e.g.
    # @amplitude/analytics-core), which 500s `next dev` and blocks rule-5 QA.
    (cd fe-next-app && npm ci --no-audit --no-fund) || true
    if [ -f Gemfile ]; then
      # Install gems into vendor/bundle so Docker can find them at /workspace/vendor/bundle.
      bundle config set --local path vendor/bundle
      bundle install --quiet || true
    fi
  before_remove: |
    : # no-op (do not modify branches on workspace teardown)
  # Two clones + `npm ci` (fe-next-app) + `bundle install` (Rails) — give it
  # room so a slow install doesn't leave a half-provisioned workspace.
  timeout_ms: 600000
agent:
  max_concurrent_agents: 11
  max_turns: 25
agent_runtime:
  command: $SYMPHONY_AGENT_SHIM_PYTHON -m symphony_agent_shim
  docker_image: schoolsout-base:latest
  approval_policy: never
  thread_sandbox: workspace-write
  read_timeout_ms: 60000
  turn_sandbox_policy:
    type: workspaceWrite
  # GitHub identity used by the agent's git/gh subprocesses. When all three
  # SYMPHONY_GITHUB_APP_* vars are set, the shim mints an installation token
  # and the agent authors PRs as `symphony-orchestrator[bot]`. If any var is
  # missing, the shim falls back to GH_TOKEN/GITHUB_TOKEN from the operator's
  # environment so older runs keep working. See docs/github-app-setup.md.
  github_app_env:
    - SYMPHONY_GITHUB_APP_ID
    - SYMPHONY_GITHUB_APP_INSTALLATION_ID
    - SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH
---

# Schools Out — Symphony Workflow

Drive a Linear-tracked ticket on `schoolsoutapp/schools-out` end-to-end:
implement the ticket, run quality gates, push the branch, and open a PR
against `main`. Symphony orchestrates Linear state transitions and workpad
posts for you.

## Ticket prompt

You are working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation attempt #{{ attempt }} — workspace already exists from prior turns.
Resume; do not redo completed work.
{% endif %}

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Allowed repositories (whitelist)

Both repos are cloned at workspace creation. Touch only these:

- `./` — `schoolsoutapp/schools-out` (Rails backend; default)
- `./fe-next-app/` — `schoolsoutapp/fe-next-app` (Next.js frontend)

If diagnosis points to a repo NOT in this list, STOP and report. Do
NOT clone any other repo.

## PR base branch per repo

Team uses gitflow: the GitHub default branch (`main`) is NOT the
integration branch. PRs target the team's working branch; releases are
cut from there to `main`. Always branch off and PR against the base
branch listed below. Never target `main` unless the repo has no
integration branch.

| Repo | PR base |
| --- | --- |
| `schoolsoutapp/schools-out` | `dev` |
| `schoolsoutapp/fe-next-app` | `dev` |
| `schoolsoutapp/claude-camps-crawler` | `dev` |
| `schoolsoutapp/data-ingestion-admin` | `dev` |
| `schoolsoutapp/temporal-crawler` | `dev` |
| `schoolsoutapp/schoolsout-crawler` | `main` |
| `schoolsoutapp/v0-schools-out` | `main` |
| `schoolsoutapp/terraform-runners` | `main` |
| `schoolsoutapp/data-ingestion-tool` | `master` |

If a repo not listed above ever enters the whitelist, the table must be
updated in the same diff. Do not guess the base branch.

## Mandatory turn-1 deliverable: understanding.md

Before any `Edit` / `Write` / mutating `Bash` call, write
`state/<session>/understanding.md` with four sections:

1. **target_repos** — which whitelisted repo(s) the fix touches. Cite a
   code reference (`path/to/file.ext:line`) or a verified `curl`/`grep`
   output for each. No guessing.
2. **root_cause** — what is wrong and where. Every claim cites a
   file:line. If you catch yourself writing "I think" / "probably" /
   "might" — STOP, verify, rewrite without hedging.
3. **expected_behavior_diff** — smallest possible change. List each
   numbered AC item (`AC#1`, `AC#2`, …) → file(s) you will change.
4. **visual_wiring** — required only when any AC contains words like
   "renders", "displays", "shows", "visible", "appears", or a UI location
   ("in the footer", "in the header", "in the page", "in the sidebar").
   For each such AC: (a) name the component being created or modified with
   its file:line, AND (b) name the layout or page file that imports and
   mounts it, verified by `grep`. If no layout currently imports the
   component, your diff MUST include that import — a component that exists
   but is never mounted fails any "renders" AC by definition. If this
   section is required and missing, the artifact is incomplete.

Each section must contain at least one verified `path/to/file.ext:line`
citation backed by a prior `Read`/`grep`/`curl` call. A section with
section headers but no citations counts as missing — the file existing
is not enough.

Skipping this artifact is a hard stop, not a style preference.

## Operating rules

1. Implement only what the ticket's Acceptance Criteria require.
   - **AC-trace mandatory.** Every changed file maps to a numbered AC
     item from the issue description. PR body lists
     `AC#N → file.ext:line-range` for each AC.
   - **Karpathy / no-drive-by.** Default: inline new logic into the
     existing caller (controller, job, model). Extract to a class,
     service, builder, wrapper, or factory ONLY when call site #2
     already exists in the same diff — if you catch yourself writing a
     new class with 1 caller, stop and inline it instead. Test files do
     not count as a real call site. No quote-style swaps, no
     spontaneous docstrings, no whitespace reformat outside the diff
     scope — preserve the exact formatting of unchanged lines. Adjacent
     tech debt: mention in the PR body, do NOT fix in the same diff.
2. Branch off the target repo's PR base branch (see "PR base branch per
   repo" table above). Run `git fetch origin <base>` then
   `git checkout -B <branch-name> origin/<base>`. Never branch off
   `main` when the table lists a different base — if `git rev-parse
   --verify origin/<base>` fails after the fetch, the workspace clone is
   broken: STOP and report. Do NOT fall back to `main` (fe-next-app's
   base is `dev`, and it does exist — don't conclude otherwise from a
   shallow clone's local branch list). Branch name:
   `agents/sodev-{{ issue.identifier | split: "-" | last }}-<short-slug>`
   (lowercase, dashes).
3. One atomic commit per logical change. Concise descriptive messages.
4. Run quality gates before pushing:
   - **Rails repos** (`Gemfile` present): `bundle exec rubocop --autocorrect-all`; if
     rubocop changes files, stage them and amend the commit; then verify `bundle exec
     rubocop` exits 0.
   - **fe-next-app (Next.js)** — it is an **npm** project (tracks
     `package-lock.json`; use `npm`, never `pnpm` — `pnpm install` builds a
     strict node_modules that 500s `next dev` and blocks rule 5). From the
     `fe-next-app/` directory run `npm run code:fix` (Prettier write-in-place
     + `eslint --fix`); if it changes any files, stage them and amend the last
     commit before continuing. Then verify `npm run code:check`
     (`prettier --check` + `eslint`) exits 0. Do NOT push with outstanding
     lint or format violations.
   - **Tests — before and after (mandatory):**
     - **Rails (`Gemfile` present):** For each file you will edit, run
       `bundle exec rubocop <path/to/file.rb>` before any edit and record the
       output. After implementing, run the same command again — it must not
       introduce new violations. If the repo has an RSpec spec matching the
       changed file (`spec/**/*_spec.rb`), run
       `bundle exec rspec <spec_file> --format progress` before and after;
       both runs must pass (skip if Postgres is unavailable — document it).
     - **fe-next-app (Next.js):** For each file you will edit, from the
       `fe-next-app/` directory run
       `npm test -- --passWithNoTests --testPathPattern="<filename>"`
       before any edit and record the result. After implementing, run the same
       command again — both runs must exit 0. If the before-run already fails,
       document it in `state/<session>/understanding.md` and do not regress it
       further.
5. **UI QA self-review (mandatory when the diff touches `fe-next-app/`
   anything that renders).** Skip ONLY for pure non-visual changes
   (config, types with no runtime effect, test-only). Do this AFTER the
   quality gates in rule 4 and BEFORE opening the PR — Symphony moves the
   ticket to "In QA / Review" off your final message, so the browser proof
   has to exist by then.

   a. Start the dev server (the helper does this for you, on port 3001 —
      the staging API's CORS allowlist only accepts that port):

      ```python
      # fe-next-app/qa_check.py — write this file, then run it with `python`
      import sys; sys.path.insert(0, "/opt/qa")
      from qa_helpers import provision_account, inject_session, dev_server, evidence_context, find_activity, write_report

      with dev_server("fe-next-app", build_sha="vqa") as base:
          email, access, refresh, user = provision_account()   # fresh staging account
          with evidence_context("fe-next-app/qa-evidence") as (page, shot):
              assert inject_session(page, base, access, refresh, user), "auth failed"
              page.goto(f"{base}/parents/<the-page-your-AC-touches>")
              page.wait_for_timeout(8000)
              shot("before")
              # ... exercise each AC: click the control, assert the new text/element ...
              checks = [{"name": "AC#1 ...", "pass": <bool>, "detail": "..."}]
              shot("after")
          ok = write_report("fe-next-app/qa-evidence", "{{ issue.identifier }}", checks)
          sys.exit(0 if ok else 1)
      ```

      `find_activity(lambda a: len(a.get("description") or "") > 200, access)`
      gets a real staging row when an AC needs specific data (e.g. a
      long-description activity). `qa_helpers` is stdlib-only; chromium is
      pre-installed in the image. Inspect the real DOM to pick selectors —
      generic role/name guesses miss (the SODEV-556 toggle is a `<button>`
      named "Read more" / "Show less", not `name="more"`).

   b. Run `python fe-next-app/qa_check.py`. Three outcomes:
      - **FAIL** — the check ran and an AC assertion came back false. The bug
        is in the code you just wrote: fix it from the existing diff (do not
        start over), re-run the quality gates, re-run `qa_check.py`. Cap: 2
        fix attempts. If still failing after 2, STOP and report what the QA
        check caught — do not open the PR.
      - **BLOCKED** — the dev server won't start, or 500s on a route you did
        NOT touch. Confirm it's pre-existing with `git stash`: if the same
        error happens with your changes removed, it's an environment issue,
        not your bug — do NOT spend fix attempts on it. Still run your unit
        tests (`npm test -- --testPathPattern="<filename>"` from
        `fe-next-app/`); record them plus the blocking error in
        `qa-report.md` / `verdict.json` (`"browser_qa": "BLOCKED"`); note it
        in the PR body; then proceed to open the PR.
      - **PASS** — proceed.
   c. After PASS or BLOCKED: do **NOT** commit `qa-evidence/`. The report is
      `.md`/`.json` and fe-next-app's lint runs
      `prettier --check "**/*.{...,md,json}" --ignore-path .gitignore`, so a
      committed `qa-evidence/` turns CI red. Instead append the line
      `qa-evidence/` to `fe-next-app/.gitignore`, and commit only that
      `.gitignore` change plus `qa_check.py` in their own commit. Symphony
      reads `qa-evidence/` straight from the workspace and uploads the
      screenshots, `session.webm` and `qa-report.md` to the Linear ticket
      automatically. Paste the `qa-report.md` table into the PR body under a
      `## QA self-review` heading.
6. Push the branch and open a PR with `gh pr create`:
   - **Pre-PR base branch check (mandatory before any `gh pr create` call)**:
     Run `git log --oneline origin/dev..HEAD` (or the repo's base per the
     table). The output must show only your commits. If it is empty or shows
     unrelated history, you branched off the wrong ref — stop, re-branch from
     `origin/dev`, cherry-pick your commits, and verify again before pushing.
   - **Base branch**: pass `--base dev` for `schools-out` and `fe-next-app`
     (see table above). Never omit `--base`. Never PR against `main` unless
     the table says so. A PR with the wrong base must be closed and reopened —
     do not retarget after the fact.
   - Title: `[{{ issue.identifier }}] <one-line>`
   - Body: 2–4 sentence summary + `Linear: {{ issue.url }}` + the
     `## QA self-review` table from rule 5c when that step ran.
   - Apply label `symphony` (create with color `#7C3AED` if missing).
   - Do **not** add reviewers via `--reviewer`; the agent's git identity
     is the operator (`viniciuscffreitas`) and GitHub rejects self-review
     with HTTP 422. The operator monitors PRs via the Linear workpad.
   - **Never** call `gh pr merge`. Humans merge.
7. **Visual-AC mount check** — before writing any code, if an AC uses
   "renders", "displays", "shows", "visible", or a UI location noun:
   run `grep -r "ComponentName" src/ --include="*.tsx" -l` to verify
   the component is imported by at least one layout or page file (not
   just its own file and tests). If the grep returns only the component's
   own file, the import into the layout IS part of the AC scope — add it.
   Document the verified mount point in `visual_wiring` (section 4 of
   `understanding.md`). This check caught SODEV-851 post-hoc: SiteFooter
   was built + tested but never mounted, so the badge was invisible on
   staging. Do not repeat this class of bug.

## Hard stops

- Do not modify paths outside the cloned workspace.
- Do not push to `main` directly. Do not push to any base branch listed
  in the "PR base branch per repo" table directly — always go through a
  PR.
- Do not bypass branch protections, CI, or `--no-verify` git hooks.
- Do not clone any repo not listed in "Allowed repositories" above.
- Do not run `Edit` / `Write` before `state/<session>/understanding.md`
  exists with all four sections populated (visual_wiring required when
  any AC uses render/display/show/visible language).
- Do not open the PR for a `fe-next-app/` UI change while `qa_check.py`
  reports **FAIL** (rule 5b) — an AC assertion is false. Two fix attempts,
  then stop and report; never ship a UI change the browser check rejects.
  A **BLOCKED** verdict (dev server / env issue, confirmed pre-existing via
  `git stash`) is not a FAIL — open the PR with the block documented.
- If auth/permissions/tooling feels off (token errors, repo not found),
  stop. Do not retry blindly. The orchestrator captures your last message
  on the Linear workpad — say what is wrong and exit.

When you finish a clean PR, end your turn with a short summary that
includes the PR URL, `git diff --stat origin/dev..HEAD`, and — when rule 5
ran — the QA self-review verdict (pass + the check table, or why it was
skipped). Do not call any Linear API yourself; Symphony moves the issue
state and posts the workpad based on your final message.
