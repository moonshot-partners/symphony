# Symphony UI MVP — Design Spec

Date: 2026-04-30
Status: Approved (verbal, brainstorming companion)
Author: Vini + Claude (brainstorming session)
Related: `elixir/docs/plans/symphony-pilot-sodev-789.md`

## Context

Symphony today is a headless orchestrator: it polls Linear, dispatches agents, and exposes a JSON observability API at `localhost:4000` (`/api/v1/state`, `/api/v1/:identifier`, `/healthz`, `/api/v1/refresh`). There is no UI. Non-technical stakeholders cannot watch the system work — they only see the eventual PR on GitHub or the comment on the Linear issue.

The pilot at schoolsout (SODEV-789, María et al.) confirmed Symphony ships PRs end-to-end. Audience grows beyond engineers (Juan + non-technical reviewers per `reference_schoolsout_team.md` memory). Need a board-style UI that lets non-technical users see "what is the agent doing right now" without reading logs.

## Goals

1. **Read-only kanban board** showing all Linear issues from the configured project, grouped by state column.
2. **Live agent activity overlay** on cards whose issues are currently running through Symphony — last event, turn count, spinner.
3. **Real-time updates** — when an issue moves between Linear states, the card animates to the new column. When a new agent event fires, the card updates without page reload.
4. **AI-native, AI-first stack** matching what Anthropic / Vercel / OpenAI ship publicly — Next.js 15 + TypeScript + shadcn/ui + Tailwind v4. Independently deployable lego brick.
5. **Plug into existing Symphony backend** with no architectural changes to the orchestrator. Backend additions are 2 endpoints + CORS.

## Non-goals (v0)

Out of scope explicitly:

- Auth / user accounts (localhost only).
- Multi-project Linear support (Symphony itself is single-project today via `Config.settings!().tracker.project_slug`).
- Drag-and-drop card movement (would require write-back to Linear `issueUpdate`).
- Pause / cancel / retry agent buttons (write-side, deferred to v1).
- Agent run detail view / mini-log inside the card (card option C from brainstorming, deferred).
- Production deploy pipeline. Localhost only for v0; Vercel deploy is a follow-up.
- Eval brick (Braintrust / Inspect). Memory `reference_vercel_labs_eval_repos.md` already documents post-MVP intent.
- Sandbox brick (e2b.dev / Modal). Symphony's local `/tmp` workspace is acknowledged as inadequate for production but kept as-is for v0.

## Architecture — lego bricks

```
[Linear project (single)]
        │ GraphQL polling (existing)
        ▼
[Symphony Orchestrator]   ← Elixir, existing
   └─ ObservabilityPubSub  ← existing, broadcasts on every poll tick
        │ HTTP / SSE
        ▼
[symphony-ui]             ← NEW separate repo, Next.js 15
   read-only board view
```

Bricks deferred to post-MVP (called out so the architecture stays aligned):

```
[Sandbox brick]  ← e2b.dev / Modal — replaces local /tmp workspace
[Agent brick]    ← claude-agent-sdk — already pluggable via Symphony's runner
[Eval brick]     ← Braintrust / Inspect — scores agent runs after PR ships
```

The UI brick reads from Symphony's existing JSON contract. Symphony does not import or know about the UI. Either side can be replaced without touching the other.

## Backend additions (Elixir, in this repo)

### 1. `GET /api/v1/board`

New endpoint returning all Linear issues for the configured project, grouped by state column.

Response shape:

```json
{
  "generated_at": "2026-04-30T20:00:00Z",
  "columns": [
    {
      "key": "todo",
      "label": "Todo",
      "linear_states": ["Backlog", "Todo"],
      "issues": [ /* Issue objects */ ]
    },
    {
      "key": "in_progress",
      "label": "In Progress",
      "linear_states": ["In Progress", "In Review"],
      "issues": [ /* ... */ ]
    },
    {
      "key": "done",
      "label": "Done",
      "linear_states": ["Done", "Cancelled", "Duplicate"],
      "issues": [ /* ... */ ]
    }
  ]
}
```

Issue object (subset of `SymphonyElixir.Linear.Issue`):

```json
{
  "id": "uuid",
  "identifier": "SODEV-789",
  "title": "Add robots.txt",
  "url": "https://linear.app/...",
  "state": "In Progress",
  "assignee": { "id": "uuid", "name": "Vini", "display_name": "vini" },
  "labels": ["seo"],
  "priority": 2,
  "has_pr_attachment": true,
  "agent_status": {
    "running": true,
    "session_id": "abc-123",
    "last_event": "writing test for /robots.txt",
    "turn_count": 7,
    "started_at": "2026-04-30T19:45:00Z",
    "tokens": { "total_tokens": 2400 }
  }
}
```

`agent_status` joins the issue with the matching entry in `Orchestrator.snapshot.running` by `issue_id` (the running list only). When the issue is running, `agent_status.running = true` plus the live-event fields. When the issue appears in `Orchestrator.snapshot.retrying`, `agent_status.running = false` plus `retry_attempt` and `retry_reason`. When the issue is in neither list, `agent_status` is `null`.

**Backend prerequisite — extend `Linear.Issue` struct.** The current `normalize_issue/2` (`linear/client.ex:464-484`) keeps only `assignee_id`. Card needs the assignee's display name for initials. Extend the struct with `assignee_name :: String.t() | nil` and `assignee_display_name :: String.t() | nil`, populated from the same GraphQL response (`assignee.name`, `assignee.displayName`). No GraphQL schema change — the fields are already in the existing `@query`.

**Implementation:** new presenter function `Presenter.board_payload/2`. Backend uses existing `Linear.Adapter.fetch_issues_by_states/1` with the union of all column states. The state-name list is derived from `Config.settings!().tracker.active_states ++ terminal_states ++ ["Backlog", "In Review"]` deduped. To keep MVP simple, the column mapping table is hardcoded in the presenter. Future: make it driven by config.

`fetch_issues_by_states/1` is the right entry point because it does not apply the `assignee_filter` (unlike `fetch_candidate_issues/0`). The board must show all issues, regardless of assignee.

### 2. `GET /api/v1/stream` (Server-Sent Events)

New endpoint streaming dashboard updates over SSE. Subscribes to `ObservabilityPubSub` topic `observability:dashboard`, sends a `data: ping\n\n` heartbeat every 15s, and on every `:observability_updated` message sends:

```
event: board_updated
data: {"generated_at":"2026-04-30T20:00:01Z"}
```

UI receives the event and re-fetches `GET /api/v1/board`. Pull-on-push pattern — the SSE event is just the trigger; the canonical state is one HTTP call away. Avoids cramming serialized state into SSE frames and keeps both endpoints independently testable.

**Implementation:** Plug controller using `Plug.Conn.send_chunked/2`. Subscribes via `ObservabilityPubSub.subscribe/0` in the controller process before chunking. Closes cleanly on client disconnect (Bandit handles this).

### 3. CORS

Permissive CORS plug for `http://localhost:3000` on `/api/v1/*` only. No CORS dep needed — manual `put_resp_header` plug. `OPTIONS` preflight returns `204`.

## UI brick (`symphony-ui` — new repo)

Located at `~/Developer/symphony-ui` (sibling to `symphony`). Independent git repo from day 1.

### Stack

- **Next.js 15** (App Router, RSC). Latest stable.
- **TypeScript** (strict).
- **Tailwind v4**.
- **shadcn/ui** components (`Card`, `Badge`, `ScrollArea`).
- **TanStack Query v5** for `/api/v1/board` fetching and revalidation.
- **`@microsoft/fetch-event-source`** for SSE consumption (handles reconnect, more reliable than browser `EventSource` for non-2xx).
- **`motion/react`** (Framer Motion 12) for column-transition animation.
- **pnpm** as package manager.

No Vercel AI SDK in v0 — not streaming LLM tokens, just board state. Add later if streaming agent log into a detail pane (deferred).

### File layout

```
symphony-ui/
├── app/
│   ├── layout.tsx
│   ├── page.tsx              ← / route, board view
│   └── globals.css
├── components/
│   ├── board.tsx             ← 3-column kanban
│   ├── column.tsx            ← single column with header + scroll
│   ├── issue-card.tsx        ← idle card
│   ├── running-card.tsx      ← B variant: spinner ring + last_event line
│   └── ui/                   ← shadcn primitives
├── lib/
│   ├── api.ts                ← fetch /api/v1/board + types
│   ├── stream.ts             ← SSE subscription hook
│   └── types.ts              ← TypeScript mirror of API contract
├── public/
├── package.json
├── tailwind.config.ts
├── tsconfig.json
└── README.md
```

### Component anatomy

**`<Board>`** — top-level. Mounts on `/`. Uses `useQuery` for `/api/v1/board` with `staleTime: 0`. Subscribes to SSE via `useStream`. On `board_updated` event, calls `queryClient.invalidateQueries(['board'])`. Renders 3 `<Column>`.

**`<Column>`** — header (label + count) and a vertical list of cards. Wraps cards in `motion.div` with `layout` prop so cross-column moves animate. Empty state: subtle "—".

**`<IssueCard>`** — identifier, title, assignee initials, label badges, PR badge if `has_pr_attachment`. Used for cards without `agent_status.running`.

**`<RunningCard>`** — variant B from brainstorming:
- Border: `border-2 border-blue-500`.
- Top-right: SVG progress ring (`<svg>` + animated `stroke-dashoffset`).
- Title row.
- 1-line agent activity strip: `▸ {last_event}` in monospace, blue-tinted background.
- Bottom row: `@assignee · turn 7`.

**Animation:** `motion.div layout` with `transition={{ type: "spring", duration: 0.4 }}`. When a card's parent column changes between renders, Framer animates the transform automatically. CSS-only fallback: `transition: transform 200ms ease`.

### Theme

Dark by default, matching brainstorming mockups. Colors:
- Background: `#0d1117`
- Card surface: `#161b22`
- Card border idle: `#30363d`
- Card border running: `#58a6ff`
- Done accent: `#3fb950`
- Text primary: `#c9d1d9`
- Text muted: `#8b949e`

Light theme deferred. WCAG AA contrast verified for the dark palette only in v0.

## Data flow

1. Browser opens `http://localhost:3000/`.
2. Next.js renders `<Board>` (server component shell + client component for interaction).
3. Client mounts → TanStack Query fetches `GET http://localhost:4000/api/v1/board`.
4. Backend builds payload: queries Linear via existing client + joins with `Orchestrator.snapshot.running`.
5. UI renders 3 columns + cards.
6. Client opens SSE connection to `GET http://localhost:4000/api/v1/stream`.
7. Symphony orchestrator ticks → `ObservabilityPubSub.broadcast_update/0` fires.
8. SSE handler emits `event: board_updated` to all subscribers.
9. UI receives → invalidates `['board']` query → refetch → re-render with diff.
10. If a card moved column or agent_status changed, Framer Motion animates the transition.

## Testing strategy

### Backend (Elixir)

- `Presenter.board_payload/2` — pure function, unit-tested with seeded `Orchestrator.snapshot` mock and seeded Linear client. Covers: empty board, all columns populated, card with agent_status running, card with agent_status nil, unknown Linear state (falls into "Todo" by default with warning log).
- `ObservabilityApiController.board/2` — integration test with `Phoenix.ConnTest`, asserts JSON shape and status 200.
- `ObservabilityApiController.stream/2` — integration test with `Phoenix.ConnTest`, asserts `text/event-stream` content-type and that broadcasting `:observability_updated` produces a chunked frame with `event: board_updated`.
- CORS plug — unit test on `OPTIONS /api/v1/board` returns 204 with the expected headers.

### Frontend (Next.js)

- **Vitest + React Testing Library** for components. Covers: column counts, running-card rendering, card sort.
- **Playwright** smoke test (1 spec) — visits `/`, mocks `/api/v1/board`, asserts 3 columns render with the expected card titles.
- No SSE end-to-end test in v0 (covered by manual smoke).

### Manual smoke (must pass before declaring done)

1. Boot Symphony with `LINEAR_API_KEY` set: `mix run --no-halt`.
2. Boot UI: `pnpm dev`.
3. Open `http://localhost:3000`.
4. Verify all real schoolsout Linear issues render under the right column.
5. Trigger Symphony to dispatch (or wait for normal poll cycle to pick up an issue).
6. Verify the card flips to running variant within ~3s of the orchestrator tick.
7. Move a Linear issue manually (in Linear UI) from "Todo" to "In Progress". Verify card animates to the In Progress column on the next tick.

## Implementation phases

Concrete sequencing for the writing-plans handoff:

**Phase 1 — Backend API (Elixir, this repo)**

1. Extend `Linear.Issue` struct + `normalize_issue/2` to keep `assignee_name` and `assignee_display_name`. Tests (RED → GREEN).
2. Add `Presenter.board_payload/2` + tests (RED → GREEN). Joins issues with `Orchestrator.snapshot.running` and `.retrying`.
3. Add `ObservabilityApiController.board/2` + route + tests.
4. Add `ObservabilityApiController.stream/2` (SSE) + route + tests.
5. Add CORS plug for `/api/v1/*` + tests. `OPTIONS` preflight returns 204.
6. Verify gate: `mix lint && mix test`.
7. Shadow gate.
8. Review gate.
9. Commit + push (branch `feature/codex-to-claude-migration` is non-protected, auto-push allowed per devflow `Autômato Seguro`).

**Phase 2 — UI scaffold (`symphony-ui` new repo)**

1. `mkdir ~/Developer/symphony-ui && cd $_ && git init`.
2. `pnpm create next-app@latest .` with TypeScript, Tailwind, App Router, no src/, no eslint stylistic.
3. `pnpm dlx shadcn@latest init` → dark theme.
4. `pnpm add @tanstack/react-query @microsoft/fetch-event-source motion`.
5. Install shadcn primitives: `card`, `badge`, `scroll-area`.
6. Initial commit.

**Phase 3 — UI implementation**

1. Frontend Gate: invoke `frontend-design:frontend-design` for layout polish review.
2. `lib/types.ts`: TypeScript mirror of board API.
3. `lib/api.ts`: `fetchBoard()` with TanStack Query.
4. `lib/stream.ts`: `useStream()` hook with `fetch-event-source`.
5. `components/issue-card.tsx`, `running-card.tsx`, `column.tsx`, `board.tsx`.
6. `app/page.tsx`: client `<QueryClientProvider>` wrapping `<Board>`.
7. Vitest + Playwright tests.
8. Verify: `pnpm typecheck && pnpm test && pnpm lint && pnpm build`.

**Phase 4 — Wire-up + manual smoke**

1. Boot Symphony locally.
2. Boot UI locally.
3. Walk the manual smoke checklist above.
4. Capture before/after screenshot (saved to `docs/media/symphony-ui-mvp-v0.png`).
5. Commit final fixes + push.

## Risks & open questions

- **Linear state mapping is hardcoded.** Some Linear projects use custom states ("In QA", "Blocked", etc). Unknown states fall into "Todo" with a log warning. Acceptable for MVP (single project, schoolsout has standard states); document in README.
- **SSE behind corporate proxies / serverless platforms** can buffer chunks. Localhost is fine. Production deploy needs validation. Out of scope v0.
- **Symphony `/api/v1/board` requires Linear API call on every request.** Could be heavy on big projects. Acceptable: Linear has 50-issue page size, full project on schoolsout fits in 1-2 pages. Add caching only if measured to be a problem (YAGNI).
- **Authentication.** Localhost only. If user wants to demo to non-technical stakeholders remotely, must add auth (Auth.js, Clerk, or basic Vercel password). Tracked as v1.
- **Card density at scale.** Done column can grow unbounded over time. v0 shows everything; no pagination. If schoolsout's Done column grows past 100 cards, need to add "Show last 30" filter. Not blocking MVP.
- **Agent_status freshness.** Orchestrator snapshot is point-in-time. Between poll ticks (default 5min), a card might still show "running" after agent finished if PR-attached but Linear state has not yet flipped. Mitigation: SSE pushes on every tick; tick interval can be lowered for demos via env. Already documented in `Orchestrator.handle_info`.

## Future work (deferred bricks)

- **Eval brick.** Per memory `reference_vercel_labs_eval_repos.md`: post-MVP. Inspect (Anthropic OSS) is the leading candidate — runs against transcripts, integrates with Linear comments. Ties into Symphony's `Workpad` comment trail.
- **Sandbox brick.** e2b.dev for ephemeral filesystem + network isolation per agent run. Replaces `Workspace` module's local `/tmp` mount. Needed before opening Symphony to untrusted code (currently trusted-environments-only per repo README warning).
- **Auth + remote deploy.** Vercel deploy for UI, Auth.js with Linear OAuth for SSO. Symphony backend behind ngrok or Tailscale.
- **Write-side actions.** Trigger-now button, pause/cancel agent, drag-and-drop card. Requires authenticated session.
- **Card detail pane.** Variant C from brainstorming (mini-log inline) becomes a side drawer with full agent transcript + token chart.

## Approval

Verbal approval recorded in brainstorming session 2026-04-30:

- Layout: A (kanban classic, 3 columns).
- Card: B (active variant — progress ring + last_event line + turn count).
- Scope: Read-only.
- Stack: Next.js + shadcn/ui + Tailwind, separate repo `symphony-ui`.
- Deferred bricks: eval, sandbox, auth.

User explicitly directed: "100% autonomy e2e following devflow perfectly". User-review gate on this spec is **skipped** per that directive. Implementation proceeds straight to `superpowers:writing-plans`.

End of design.
