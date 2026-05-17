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
  on_complete_state: "In Code Review"
  on_pr_merge_state: "Ready for QA"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/schoolsout-workspaces
hooks:
  after_create: |
    # Gate A — install integrity: fail loudly on any non-zero exit. The hook
    # used to mask install failures with `|| true`, which let a half-populated
    # node_modules through and turned every downstream `npm test`/QA run into
    # a silent BLOCKED. `NPM_CONFIG_IGNORE_SCRIPTS=1` is already injected by
    # Symphony's hook runner (Workspace.hook_env/0) so postinstall scripts
    # like @sentry/cli don't run here and corrupt the install when their
    # secrets aren't present.
    set -euo pipefail
    # Primary repo at workspace root.
    git clone --depth 1 -b dev https://github.com/schoolsoutapp/schools-out .
    # Clone lands on `dev` so AGENTS.md/CLAUDE.md (committed to dev, not main)
    # are readable at Step 0 before any branching. The explicit fetch below
    # ensures origin/dev ref exists even if git's shallow clone omits it.
    git fetch --depth=1 origin dev:refs/remotes/origin/dev
    git remote set-head origin dev
    # Frontend repo at ./fe-next-app — eliminates the SODEV-827 class of
    # bugs where the agent had to clone the right repo mid-run after
    # burning turns on the wrong one. Whitelist mirrored in the prompt
    # body's "Allowed repositories" section.
    git clone --depth 1 -b dev https://github.com/schoolsoutapp/fe-next-app fe-next-app
    # Same as above: clone dev so AGENTS.md is in the working tree at Step 0.
    git -C fe-next-app fetch --depth=1 origin dev:refs/remotes/origin/dev
    git -C fe-next-app remote set-head origin dev
    # fe-next-app is an npm project (versions package-lock.json). Install deps
    # here with `npm ci` — if `pnpm install` runs later it builds a strict
    # node_modules that fails undeclared transitive imports (e.g.
    # @amplitude/analytics-core), which 500s `next dev` and blocks rule-5 QA.
    (cd fe-next-app && npm ci --no-audit --no-fund)
    # Gate A — verify the install actually produced a working test toolchain.
    # If jest can't enumerate its tests, node_modules is half-provisioned and
    # the agent would crash later in `npm test`/`qa_check.py` with no signal
    # back to Symphony. Fail the workspace creation instead, loud.
    (cd fe-next-app && npx --no-install jest --listTests > /dev/null)
    if [ -f Gemfile ]; then
      # Install gems into vendor/bundle so Docker can find them at /workspace/vendor/bundle.
      bundle config set --local path vendor/bundle
      # --no-color (not --quiet) so the error message survives in the hook
      # output buffer when bundle exits non-zero. --quiet swallows the one
      # diagnostic line we need to debug auth/native-extension failures.
      bundle install --no-color
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
qa:
  # Path inside the workspace where view-layer tests drop the QA evidence
  # bundle (screenshots, session.webm, qa-report.md). Symphony reads this dir
  # post-PR and posts the bundle to the Linear ticket. Schools-out keeps its
  # frontend in ./fe-next-app, so evidence lands at fe-next-app/qa-evidence/.
  evidence_subpath: fe-next-app/qa-evidence
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

## Step 0 — Read repo conventions (mandatory, before any code)

Before writing `understanding.md`, before any `Edit` / `Write`, before
branching: read every repo-level instruction file in the workspace.
These files override any framework default and any phrasing in the
Linear description.

Run, at turn 1, for each repo you may touch (root and any subdir the
ticket targets):

```
cat AGENTS.md 2>/dev/null
cat CLAUDE.md 2>/dev/null
ls AGENTS.md CLAUDE.md 2>/dev/null
```

For every file path the Linear ticket asks you to **create**, first run
`ls` on it. If the file already exists, you **extend** it; you do not
recreate it under a different name. Example: if the ticket says
"create `src/middleware.ts`" but the repo ships `src/proxy.ts` (Next.js
16's new convention, documented in `CLAUDE.md`/`AGENTS.md`), add the
new logic to `src/proxy.ts` and report the deviation in your
`understanding.md` rather than creating `middleware.ts`.

Precedence, highest first:
1. Repo `AGENTS.md` / `CLAUDE.md` (closest to the file you edit wins).
2. This workflow.
3. The Linear ticket description.
4. Framework defaults.

A ticket that conflicts with `AGENTS.md`/`CLAUDE.md` is a ticket bug.
Note the conflict in `understanding.md` `root_cause` and follow the
repo convention.

## Mandatory turn-1 workpad post: AC Extracted

Your very first turn-end message — the one Symphony posts to the Linear
workpad — must be a numbered breakdown of the acceptance criteria you
intend to satisfy, in this exact format:

```
## AC Extracted

1. <binary pass/fail statement, e.g. "/vendor/dashboard h1 contains
   vendor.business_name when vendor.approved=true">
2. ...
```

Every item must be **testable without subjective interpretation** — a
human reading the rendered page should be able to mark it pass or fail in
under five seconds. If the issue description contains a soft requirement
that cannot be reduced to a binary statement ("improve UX", "make it
better", "more polished"), your first turn-end message is instead:

```
## BLOCKED: AC not testable

The following items cannot be expressed as binary pass/fail:
- "<verbatim quote from the issue>"
- ...

Suggested rewrites:
- "improve dashboard" → "/vendor/dashboard renders h1 with business_name"
- "make it faster" → "FCP < 2.5s on Lighthouse mobile preset"

Needs PM rewrite before this ticket is workable.
```

After a BLOCKED post, stop calling tools for the rest of the turn. Do
NOT write any files, do NOT clone any repo, do NOT branch. Wait for the
PM to rewrite the description. Symphony will re-dispatch on the next
poll; if AC is still subjective, post BLOCKED again — that is the
correct behavior and costs essentially nothing.

The numbered AC list is the **source of truth** for every downstream
artifact:
- `understanding.md` references AC#N in `expected_behavior_diff`.
- PR body references AC#N in the file-mapping table.
- `qa_check.py` uses the same AC#N labels in `expect_*` annotations and
  the `## QA self-review` table.

Re-numbering or silently dropping an AC item between turn-1 and the PR
is a process violation.

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
   If the issue description references a specific feature branch that should
   already exist (e.g. "branch off `feat/sodev-NNN-slug`") and that branch
   does NOT exist on remote after `git fetch origin`: do **not** silently
   fall back. Instead, record the discrepancy in
   `state/{{ issue.identifier | downcase }}/understanding.md` under a
   **"Branch deviation"** heading — note the referenced branch, confirm it is
   absent from `git branch -r`, and state that you branched off
   `origin/<base>` as the WORKFLOW default. Continue — the missing branch is
   a spec gap, not an agent error.
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

   **Pick your QA path based on the project layout (check ONCE up front):**

   - If `fe-next-app/playwright.config.ts` exists → use the
     **project-owned Playwright Test path** (rule 5-PT below). The
     project owns its specs, fixtures and locators; you add/edit a spec
     in the same PR as the feature.
   - Otherwise → use the **Symphony harness path** (`qa_helpers` — rule
     5-LH below; this is the legacy path).

   The downstream evidence step is identical for both: `fe-next-app/
   qa-evidence/qa-report.md` + screenshots + `session.webm`. Symphony
   reads that dir and posts the proof to the Linear ticket automatically.

   ### 5-PT — Project-owned Playwright Test path

   a. **Stable selector for every visual AC** (same rule as 5-LH-a).

   b. **Add a spec to `fe-next-app/e2e/`** next to the existing ones:
      - `e2e/parents/<feature>.spec.ts` for authenticated parents flows
        — the project's `parents` Playwright project reuses
        `playwright/.auth/parents.json` (provisioned once by the
        `setup-parents` project) so the spec opens already
        authenticated, no per-spec login.
      - `e2e/anon/<feature>.spec.ts` for anonymous flows.
      Specs assert against the `data-testid` you added; reuse the
      helpers in `e2e/fixtures/staging-api.ts` if the AC needs the
      staging API directly.

   b'. **Capture PM-facing visual evidence per test, on PASS too** — this is
      the audience-facing artifact. The PM reading the Linear ticket needs to
      SEE what "PASS" looks like rendered, not just `passed in 2078ms`. The
      project ships a `captureEvidence(page, target, testInfo)` helper at
      `fe-next-app/e2e/helpers/captureEvidence.ts` that does the right thing
      (scroll the target into view, outline it in magenta, write both a
      viewport shot and an element close-up into `qa-evidence/<slug>-…png`).
      Call it after your last assertion — once per Playwright test. The
      session video (`session.webm`) and the Playwright trace (`session.zip`,
      openable at https://trace.playwright.dev) come from
      `playwright.config.ts` (`video: "on"`, `trace: "on"`) — no per-spec
      call needed.

      ```ts
      import { test, expect } from "@playwright/test";
      import { captureEvidence } from "../helpers/captureEvidence";

      test("geographic-sibling header — Summer Camps prefix when filter is set", async ({ page }, testInfo) => {
        await page.goto("/summer-camps/austin?filter=soccer");
        const heading = page.getByTestId("geographic-sibling-header");
        await expect(heading).toHaveText("Soccer Summer Camps in Nearby Cities");
        await captureEvidence(page, heading, testInfo);
      });
      ```

      Symphony's QaEvidence uploader (Elixir-side, no agent code needed)
      scans `qa-evidence/*.png` after the agent finishes, uploads each shot
      as a Linear file attachment, embeds them inline in the QA
      self-review comment under `### Screenshots`, and uploads
      `session.webm` + `session.zip` as separate links in the same comment.
      This is mandatory for every Playwright Test the agent writes — a
      passing test with no scrolled+highlighted screenshots defeats the
      PM-visibility contract that makes Symphony worth running.

   c. **Run from `fe-next-app/`** (cwd):
      `CI=1 npm run e2e -- --project=<parents|anon>` (`CI=1` blocks
      `reuseExistingServer` so the build runs cleanly per attempt).
      Three outcomes (same as 5-LH):
      - **PASS** — proceed.
      - **FAIL** — assertion failed. Fix the implementation from the
        existing diff (do not start over). Cap 2 fix attempts. Stop and
        report after 2 — do not open the PR with a failing browser
        check.
      - **BLOCKED** — webServer or staging API never comes up. Confirm
        pre-existing with `git stash` (same logic as 5-LH-c). Document
        BLOCKED via `qa_publish.py --blocked "<reason>"`.

   d. **Promote evidence into `qa-evidence/`** so Symphony's uploader
      finds it. After the test run, from `fe-next-app/`:
      `python /opt/qa/qa_publish.py`. That adapter reads
      `test-results/results.json` + trace dirs, copies probative
      screenshots + the video per test, and writes
      `fe-next-app/qa-evidence/qa-report.md` + `verdict.json` in the
      shape Symphony already understands.

   e. **Do NOT commit `qa-evidence/`, `test-results/`,
      `playwright-report/`, or `playwright/.auth/`** — all four are
      workspace-local. The scaffold already ships those entries in
      `fe-next-app/.gitignore`; verify your PR diff has nothing from
      them. Paste the `qa-report.md` table into the PR body under
      `## QA self-review` (same as 5-LH-d).

   ### 5-LH — Legacy Symphony harness path (when no playwright.config.ts)

   a. **Pick a stable selector for every visual AC.** For each AC that says
      "renders / displays / shows / visible", find the element in your diff.
      If it has no stable `data-testid`, add one in this PR (e.g.
      `data-testid="build-badge"` on the span you changed) — that is part of
      the AC scope. You only ever assert on selectors you own; never assert
      against a regex over whole-page text (a bare `v[a-z]+` happily matches
      "vorites" inside "favorites").

      **Every new `data-testid` MUST have at least one committed consumer in
      the same PR.** `qa_check.py` is workspace-local (rule 5d) and never
      lands in the diff, so a `data-testid` whose only consumer is
      `qa_check.py` looks orphaned to anyone reviewing the merged PR —
      including `claude-pr-review`'s `pr-test-analyzer`, which flags it as
      dead test infrastructure. Pair the `data-testid` with either:
      - **(preferred)** a Jest test in the same PR that queries it
        (`getByTestId("build-badge")` inside the adjacent `*.test.tsx`).
        Light to add; runs on every CI; gives the testid a permanent
        consumer reviewers can see.
      - Or, when a Jest test is not justified for the change, switch the
        `qa_check.py` selector to a semantic one (`text=`,
        `role=`, `getByRole("heading", { name: "Pricing" })`) and remove
        the `data-testid` from the diff entirely.
      Adding a `data-testid` whose only mention in the PR is the markup
      itself is forbidden — pick one of the two paths above.

   b. Write `state/{{ issue.identifier | downcase }}/qa_check.py` using the declarative harness. You do
      NOT write Playwright — you declare assertions and the harness owns the
      browser (it starts `next dev` on port 3001, which the staging API's
      CORS allowlist requires; it handles navigation waits,
      `scroll_into_view_if_needed` through nested `overflow-y-auto`
      containers, and the screenshots). Each `expect_*` captures a screenshot
      bound to that assertion, so the evidence always frames the element
      under test — a FAILED assertion captures too:

      ```python
      # state/<issue-identifier>/qa_check.py — write this in state/, NOT in fe-next-app/.
      # Run from workspace root: `python state/<issue-identifier>/qa_check.py`
      # (the harness finds fe-next-app/ via _resolve_app_dir — cwd = workspace root is correct).
      import sys; sys.path.insert(0, "/opt/qa")
      from qa_helpers import qa_run   # also available: find_activity, write_report (BLOCKED path)

      # build_sha=None → footer shows `vdev`; pass a 7-hex to assert `v<sha>`.
      with qa_run("fe-next-app", "{{ issue.identifier }}", build_sha="abc1234") as qa:
          qa.login()                                  # fresh staging account + session
          qa.goto("/parents/<the-page-your-AC-touches>")
          qa.expect_visible('[data-testid="build-badge"]', "AC#1 - build SHA badge in footer")
          qa.expect_text('[data-testid="build-badge"]', r"^vabc1234$", "AC#1b - badge text v<sha>")
          # interact between assertions via the raw page, e.g.:
          # qa.page.get_by_role("button", name="Read more").click(); qa.page.wait_for_timeout(500)
          # qa.expect_visible('text=Show less', "AC#2 - expands on click")
          qa.note("AC#3 - unit tests both code paths pass", True, "npx jest site-footer: 12/12")
      sys.exit(0 if qa.passed else 1)
      ```

      For ACs under `/business/*` (vendor-side pages — anything the business
      app routes serve), use `qa.login_as_vendor(business_name="QA Co")`
      INSTEAD of `qa.login()`. The protected layout reads
      `user.vendor.onboarding_status` from the Zustand session; without a
      completed vendor it redirects every `/business/*` route to
      `/business/signup/about-you`, so a plain `qa.login()` would land your
      assertions on the signup wizard, not the page under test. `goto()`
      now detects this redirect and short-circuits subsequent `expect_*`
      calls — the report will show ONE navigation FAIL with the redirect
      destination instead of N identical wizard screenshots — but the right
      move is to use the vendor login from the start.

      **If setup itself can fail, use the `try_*` variant.** The SODEV-765
      run showed the failure mode: vendor promotion raised, the agent
      hand-typed a "BLOCKED — inject_session failed" note in the report,
      and `verdict.json` never recorded it (the verdict still said PASS).
      `qa.try_login_as_vendor()` returns `(ok, err)` instead of raising,
      so the failure becomes a real `note()` and the verdict reflects it:

      ```python
      with qa_run("fe-next-app", "{{ issue.identifier }}") as qa:
          ok, err = qa.try_login_as_vendor(business_name="QA Co")
          if not ok:
              qa.note("setup - vendor promotion", False, f"BLOCKED: {err}")
              sys.exit(1)
          qa.goto("/business/<page-under-test>")
          # ... expect_* calls
      ```

      Never hand-type a BLOCKED line into the report. The harness owns
      that field — either through `qa.note(..., False, "BLOCKED: ...")`
      mid-run, or through `write_report(..., notes="BLOCKED: ...")` when
      `qa_run` itself never yielded.

      **AC coverage rules (every AC must be accounted for):**
      - **Link/href ACs** (`"renders a link to X"`, `"links to /path"`):
        `expect_visible` alone is insufficient — the element may render but
        point to the wrong destination. Also assert the href:
        `qa.expect_text('[data-testid="signup-link"]', r"^/sign-up$", "AC#2b - href")`.
        `expect_text` matches against the element's `href` attribute when the
        element is an `<a>` tag (the harness checks `getAttribute("href")` if
        `innerText` doesn't match the pattern).
      - **Opacity/CSS-state ACs** (`"active slide visible"`, `"inactive slide hidden"`):
        two absolutely-positioned elements can both be "visible" to Playwright
        when visibility is controlled by `opacity` or `z-index` only. Use
        `qa.page.evaluate` to check computed style:
        `assert qa.page.evaluate('window.getComputedStyle(document.querySelector(\'[data-testid="slide-0"]\'')).opacity') == "1"`.
        Follow with `qa.note("AC#N - slide 0 opacity:1 confirmed", True, "computed opacity == 1")`.
      - **Every AC must appear**: go through the ticket's acceptance criteria
        one by one. Each AC must map to either an `expect_*` call or a
        `note()` with a boolean outcome. Silently skipping an AC is not
        acceptable — the evidence sanity gate does not catch gaps, but the
        reviewer will.

      `qa.page` is the raw Playwright page for clicks/typing between
      assertions; `qa.find_activity(lambda a: len(a.get("description") or "") > 200)`
      returns a real staging row when an AC needs specific data. **At least
      one `expect_*` must run** — a run with only `note()` calls (no
      screenshots), or no assertions at all, is failed by the harness's
      evidence sanity gate. Inspect the real DOM to pick selectors — generic
      role/name guesses miss.

   c. Run it from the **workspace root**:
      `python state/{{ issue.identifier | downcase }}/qa_check.py`.
      Do NOT cd into fe-next-app first — the harness resolves
      `fe-next-app/` from `workspace_root/fe-next-app/package.json`.
      Three outcomes:
      - **FAIL** — `qa.passed` is false: an assertion came back false, or no
        probative evidence was captured. The bug is in the code you just
        wrote: fix it from the existing diff (do not start over), re-run the
        quality gates, re-run `qa_check.py`. Cap: 2 fix attempts. If still
        failing after 2, STOP and report what the QA check caught — do not
        open the PR.
      - **BLOCKED** — `qa_run(...)` raised before yielding (the dev server
        won't start, or 500s on a route you did NOT touch). Confirm it's
        pre-existing with `git stash`: if the same error happens with your
        changes removed, it's an environment issue, not your bug — do NOT
        spend fix attempts on it. Write a BLOCKED report with `checks=[]`:
        `write_report("qa-evidence", "{{ issue.identifier }}", [],
        notes="BLOCKED: <reason>")` (run from `fe-next-app/`). A BLOCKED
        report writes `verdict.pass = false` on purpose — a run with no
        browser evidence proves nothing, so don't dress it up as a green QA
        pass. **Do NOT pass unit-test results in `checks=` on a BLOCKED run.**
        SODEV-765 lesson: agents have listed `[{name: "Unit: foo", pass: true}]`
        as `checks`, which renders under `## Evidence` in qa-report.md and
        makes the BLOCKED look like a partial-pass to a reviewer skimming the
        Linear comment. Unit tests are useful, but they are NOT browser
        proof — keep them out of the harness's evidence channel. Mention
        `npx jest <files>` passing in the PR body as a separate paragraph
        ("unit tests covering the change: 66/66 passing"), not in the QA
        report. That is expected and does not stop you: paste the QA
        report's message into the PR body, state plainly that browser QA
        was blocked and why, and open the PR.
      - **PASS** — proceed.

   d. After PASS or BLOCKED: do **NOT** commit `qa-evidence/` or
      `state/{{ issue.identifier | downcase }}/qa_check.py` — both are
      workspace-local only and must never appear in the PR diff. The harness
      writes `.png` / `.webm` / `.md` / `.json` under `fe-next-app/qa-evidence/`
      and fe-next-app's lint runs
      `prettier --check "**/*.{...,md,json}" --ignore-path .gitignore`,
      so a committed `qa-evidence/` turns CI red. Append a `qa-evidence/`
      line to `fe-next-app/.gitignore` — newline-safe:
      `printf '\nqa-evidence/\n' >> fe-next-app/.gitignore` (a bare `echo >>`
      can glue it onto the file's last line if that line has no trailing
      newline). Commit only that `.gitignore` change (and any `data-testid`
      you added) in its own commit. Do **not** include `qa_check.py` in the
      PR diff — it lives in `state/` and is not relevant to reviewers of the
      UI change. Symphony reads `qa-evidence/` straight from the workspace
      and uploads the screenshots, `session.webm` and `qa-report.md` to the
      Linear ticket automatically. Paste the `qa-report.md` table into the
      PR body under a `## QA self-review` heading.
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
     `## QA self-review` table from rule 5d when that step ran.
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
  reports **FAIL** (rule 5c) — an assertion is false, or no evidence was
  captured. Two fix attempts, then stop and report; never ship a UI change
  the browser check rejects. A **BLOCKED** verdict (dev server / env issue,
  confirmed pre-existing via `git stash`) is not a FAIL — open the PR with
  the block documented.
- If auth/permissions/tooling feels off (token errors, repo not found),
  stop. Do not retry blindly. The orchestrator captures your last message
  on the Linear workpad — say what is wrong and exit.

When you finish a clean PR, end your turn with a short summary that
includes the PR URL, `git diff --stat origin/dev..HEAD`, and — when rule 5
ran — the QA self-review verdict (pass + the check table, or why it was
skipped). Do not call any Linear API yourself; Symphony moves the issue
state and posts the workpad based on your final message.
