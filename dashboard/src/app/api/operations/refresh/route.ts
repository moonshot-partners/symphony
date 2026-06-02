import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export async function POST() {
  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  const token = process.env.COCKPIT_API_TOKEN;
  let res: Response;
  try {
    res = await fetch(`${base}/refresh`, {
      method: "POST",
      headers: token ? { authorization: `Bearer ${token}` } : {},
      cache: "no-store",
    });
  } catch {
    return NextResponse.json({ error: "cockpit API unreachable" }, { status: 502 });
  }

  if (!res.ok) {
    return NextResponse.json({ error: `cockpit API error ${res.status}` }, { status: 502 });
  }

  return NextResponse.json(await res.json(), { status: 202 });
}
