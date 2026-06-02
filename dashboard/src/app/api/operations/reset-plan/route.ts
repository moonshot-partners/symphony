import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  return proxyIssueOperation(req, "reset");
}

async function proxyIssueOperation(req: Request, operation: string) {
  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  let identifier: string | undefined;
  try {
    const body = (await req.json()) as { identifier?: unknown };
    identifier = typeof body.identifier === "string" ? body.identifier : undefined;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (!identifier) {
    return NextResponse.json({ error: "identifier is required" }, { status: 400 });
  }

  const token = process.env.COCKPIT_API_TOKEN;
  let res: Response;
  try {
    res = await fetch(`${base}/issues/${encodeURIComponent(identifier)}/${operation}`, {
      method: "POST",
      headers: token ? { authorization: `Bearer ${token}` } : {},
      cache: "no-store",
    });
  } catch {
    return NextResponse.json({ error: "cockpit API unreachable" }, { status: 502 });
  }

  const body = await res.json();
  return NextResponse.json(body, { status: res.ok ? 200 : res.status });
}
