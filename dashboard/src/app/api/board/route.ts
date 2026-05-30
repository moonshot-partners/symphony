import { NextResponse } from "next/server";
import { BoardPayload } from "@/features/board/contract";

// Always live: never cache the board.
export const dynamic = "force-dynamic";

/**
 * BFF route: proxies the Elixir read-only cockpit API and validates the
 * payload against the board contract before it reaches the browser. Secrets
 * (the API URL and bearer token) stay server-side.
 */
export async function GET() {
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

  return NextResponse.json(parsed.data);
}
