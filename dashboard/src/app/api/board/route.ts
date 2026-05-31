import { NextResponse } from "next/server";
import { BoardPayload, type BoardPayload as BoardPayloadType } from "@/features/board/contract";

// Always live: never cache at the framework level.
export const dynamic = "force-dynamic";

// In-process cache. The board polls every ~1.5s; the upstream reads Linear,
// which is rate limited (and shared with the live agent). Without this, an open
// cockpit tab would hammer Linear and starve the agent. Serve a recent snapshot
// instead so Linear is hit at most once per TTL regardless of client count.
const TTL_MS = 20_000;
let cache: { data: BoardPayloadType; at: number } | null = null;

/** Test-only: reset the module cache between cases. */
export function __resetBoardCache() {
  cache = null;
}

/**
 * BFF route: proxies the Elixir read-only cockpit API and validates the payload
 * against the board contract before it reaches the browser. Secrets (the API
 * URL and bearer token) stay server-side. Successful responses are cached for
 * TTL_MS; errors are never cached.
 */
export async function GET() {
  if (cache && Date.now() - cache.at < TTL_MS) {
    return NextResponse.json(cache.data);
  }

  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  const token = process.env.COCKPIT_API_TOKEN;
  let res: Response;
  try {
    res = await fetch(`${base}/board`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
      cache: "no-store",
    });
  } catch {
    return NextResponse.json({ error: "cockpit API unreachable" }, { status: 502 });
  }

  if (!res.ok) {
    return NextResponse.json({ error: `cockpit API error ${res.status}` }, { status: 502 });
  }

  const parsed = BoardPayload.safeParse(await res.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "cockpit API contract mismatch" }, { status: 502 });
  }

  cache = { data: parsed.data, at: Date.now() };
  return NextResponse.json(parsed.data);
}
