import { NextResponse } from "next/server";
import { LivePayload } from "@/features/live/contract";

// Always live: never cache. Unlike the board (slow structure, cached upstream),
// this is the orchestrator's in-memory snapshot — cheap to read and changing
// every turn, so caching it would defeat the point.
export const dynamic = "force-dynamic";

/**
 * BFF route: proxies the Elixir read-only `/live` API and validates the payload
 * against the live contract before it reaches the browser. Secrets (the API URL
 * and bearer token) stay server-side. Never cached.
 */
export async function GET() {
  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  const token = process.env.COCKPIT_API_TOKEN;
  let res: Response;
  try {
    res = await fetch(`${base}/live`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
      cache: "no-store",
    });
  } catch {
    return NextResponse.json({ error: "cockpit API unreachable" }, { status: 502 });
  }

  if (!res.ok) {
    return NextResponse.json({ error: `cockpit API error ${res.status}` }, { status: 502 });
  }

  const parsed = LivePayload.safeParse(await res.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "cockpit API contract mismatch" }, { status: 502 });
  }

  return NextResponse.json(parsed.data);
}
