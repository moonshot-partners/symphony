# Symphony Cockpit — conventions for AI agents

Read this before editing. The codebase is organized to be easy for an AI (and a
human) to hold one feature in context at a time.

## Layout

- **Feature-colocated, vertical slices.** Everything for a feature lives under
  `src/features/<feature>/`: its Zod contract, data source, pure logic,
  hook, components, and tests. Do not split a feature across layer-named
  folders.
- `src/app/` is thin: routing, layout, providers. Real logic lives in features.

## Contracts

- A feature's `contract.ts` holds Zod schemas and is the single source of
  truth. **Infer types from Zod** (`z.infer`), never hand-write a parallel
  `interface`.
- Validate external data (API responses) against the schema at the boundary.
  Drift should throw, not render wrong.

## Data

- Data sources are swappable behind one function (see `board/source.ts`):
  a `mock` adapter (fixtures) for local dev and an `http` adapter for the real
  backend, selected by `NEXT_PUBLIC_DATA_SOURCE`. The app must run on `mock`
  with no backend.
- Liveness is **polling** via TanStack Query (`refetchInterval`), not
  WebSocket.

## Logic and tests

- Keep transformation logic **pure** (e.g. `board/bucket.ts`) so it is trivial
  to unit-test. Components stay thin.
- Tests are colocated (`*.test.ts`), deterministic (no clock, network, or
  randomness), and assert real behavior.
- `pnpm test` runs Vitest. `pnpm lint` and `pnpm build` must pass before push.

## Style

- Strict TypeScript. Small, focused files. Tailwind for styling. Boring,
  well-known libs only (Next, Tailwind, shadcn/ui, TanStack Query, Zod) — do
  not add a new dependency without a clear reason.
