import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

/**
 * BFF proxy for QA evidence files. The board returns same-origin URLs like
 * `/api/evidence/<issue id>/<file>`, so the browser loads screenshots and the
 * session video without ever seeing the Elixir API URL or its bearer token —
 * both stay server-side. Only the exact `<id>/<file>` shape the Elixir route
 * (`/evidence/:id/:file`) understands is forwarded; anything else is 404.
 */
export async function GET(_req: Request, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  if (!Array.isArray(path) || path.length !== 2) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }

  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  const [id, file] = path;
  const token = process.env.COCKPIT_API_TOKEN;
  const upstream = `${base}/evidence/${encodeURIComponent(id)}/${encodeURIComponent(file)}`;

  let res: Response;
  try {
    res = await fetch(upstream, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
      cache: "no-store",
    });
  } catch {
    return NextResponse.json({ error: "cockpit API unreachable" }, { status: 502 });
  }

  if (!res.ok) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }

  const body = await res.arrayBuffer();
  return new NextResponse(body, {
    status: 200,
    headers: {
      "content-type": res.headers.get("content-type") ?? "application/octet-stream",
      // evidence is replaced on republish, so allow a short shared cache only
      "cache-control": "private, max-age=60",
    },
  });
}
