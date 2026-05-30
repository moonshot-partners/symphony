import type { BoardPayload } from "./contract";

/**
 * Realistic mock payload so the board runs locally without the Elixir API.
 * State names match the schools-out tracker config, and the external links
 * (Linear issue, GitHub PR, Langfuse trace) are placeholder URLs in the shape
 * the real API returns. Swapping to the real API is an env flip, not a rewrite.
 */
const linear = (id: string) => `https://linear.app/schools-out/issue/${id}`;
const ghPr = (n: number) => `https://github.com/schoolsoutapp/fe-next-app/pull/${n}`;
const trace = (id: string) => `https://cloud.langfuse.com/trace/${id}`;

export const MOCK_BOARD: BoardPayload = {
  states: {
    active: ["Todo", "In Progress"],
    onComplete: "In Code Review",
    onExhaust: "In Code Review",
    onPromote: "Promote to Staging",
    onPrMerge: "Merged",
    onReject: "On Hold",
    terminal: ["Done", "Cancelled", "Duplicate"],
  },
  tickets: [
    {
      id: "SODEV-964",
      title: "Add empty state to saved searches",
      state: "Todo",
      agent: { status: "idle", turn: null, maxTurns: null, costUsd: null, lastAction: null },
      pr: null,
      evidence: [],
      url: linear("SODEV-964"),
      updatedAt: "2026-05-30T12:40:00Z",
    },
    {
      id: "SODEV-956",
      title: "Fix collection search debounce",
      state: "In Progress",
      agent: {
        status: "running",
        turn: 3,
        maxTurns: 20,
        costUsd: 0.41,
        lastAction: "running unit tests + lint",
      },
      pr: { number: 642, ci: "pending", url: ghPr(642) },
      evidence: [
        { id: "e1", ac: "AC 1 — debounce fires one request", kind: "image", name: "before.png", url: "#" },
        { id: "e2", ac: "AC 1 — debounce fires one request", kind: "image", name: "after.png", url: "#" },
        { id: "e3", ac: "AC 1 — debounce fires one request", kind: "video", name: "flow.webm", url: "#" },
        { id: "e4", ac: "AC 2 — no loading flicker", kind: "image", name: "flicker-1.png", url: "#" },
      ],
      timeline: [
        { label: "Read issue and extracted acceptance criteria", turn: 1, status: "done" },
        { label: "Implemented debounce in SearchInput", turn: 2, status: "done" },
        { label: "Running unit tests + lint", turn: 3, status: "active" },
      ],
      url: linear("SODEV-956"),
      traceUrl: trace("c3e398a1b2f04d7e9a"),
      updatedAt: "2026-05-30T12:46:00Z",
    },
    {
      id: "SODEV-940",
      title: "Vendor profile avatar upload",
      state: "In Code Review",
      agent: { status: "idle", turn: 11, maxTurns: 20, costUsd: 1.92, lastAction: "opened PR" },
      pr: { number: 631, ci: "passing", url: ghPr(631) },
      evidence: [
        { id: "e5", ac: "AC 1 — upload accepts png/jpg", kind: "image", name: "upload-ok.png", url: "#" },
        { id: "e6", ac: "AC 2 — rejects files over 5mb", kind: "image", name: "reject.png", url: "#" },
      ],
      timeline: [
        { label: "Read issue and extracted acceptance criteria", turn: 1, status: "done" },
        { label: "Implemented avatar upload endpoint", turn: 6, status: "done" },
        { label: "Added validation tests", turn: 9, status: "done" },
        { label: "Opened PR #631", turn: 11, status: "done" },
      ],
      url: linear("SODEV-940"),
      traceUrl: trace("a1f7c2d9e4b8401122"),
      updatedAt: "2026-05-30T11:10:00Z",
    },
    {
      id: "SODEV-933",
      title: "Search results pagination",
      state: "Promote to Staging",
      agent: { status: "idle", turn: 8, maxTurns: 20, costUsd: 1.05, lastAction: "CI green" },
      pr: { number: 638, ci: "passing", url: ghPr(638) },
      evidence: [
        { id: "e7", ac: "AC 1 — page 2 loads", kind: "video", name: "pagination.webm", url: "#" },
      ],
      url: linear("SODEV-933"),
      traceUrl: trace("d4e5f6a7b8c9001234"),
      updatedAt: "2026-05-30T10:02:00Z",
    },
    {
      id: "SODEV-430",
      title: "Filter collections by neighborhood",
      state: "On Hold",
      agent: { status: "idle", turn: 20, maxTurns: 20, costUsd: 6.1, lastAction: "exhausted turns, no PR" },
      pr: null,
      evidence: [],
      url: linear("SODEV-430"),
      traceUrl: trace("90abcdef12345678aa"),
      updatedAt: "2026-05-29T19:30:00Z",
    },
    {
      id: "SODEV-901",
      title: "Add robots.txt for staging",
      state: "Done",
      agent: { status: "idle", turn: 4, maxTurns: 20, costUsd: 0.33, lastAction: "merged" },
      pr: { number: 754, ci: "passing", url: ghPr(754) },
      evidence: [],
      url: linear("SODEV-901"),
      traceUrl: trace("fedcba9876543210bb"),
      updatedAt: "2026-05-28T16:00:00Z",
    },
  ],
};
