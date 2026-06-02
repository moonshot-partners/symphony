import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  let issueId: string | undefined;
  try {
    const body = (await req.json()) as { issueId?: unknown };
    issueId = typeof body.issueId === "string" ? body.issueId : undefined;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (!issueId) {
    return NextResponse.json({ error: "issueId is required" }, { status: 400 });
  }

  const token = process.env.COCKPIT_API_TOKEN;
  let res: Response;
  try {
    res = await fetch(`${base}/runs/${encodeURIComponent(issueId)}/stop`, {
      method: "POST",
      headers: token ? { authorization: `Bearer ${token}` } : {},
      cache: "no-store",
    });
  } catch {
    return NextResponse.json({ error: "cockpit API unreachable" }, { status: 502 });
  }

  if (res.status === 404) {
    return NextResponse.json({ error: "not_running" }, { status: 404 });
  }

  if (!res.ok) {
    return NextResponse.json({ error: `cockpit API error ${res.status}` }, { status: 502 });
  }

  return NextResponse.json(await res.json());
}
