import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

/**
 * BFF proxy for Linear-hosted issue-description images. Linear stores those on
 * `uploads.linear.app`, which 401s without the tracker API token, so a browser
 * <img> renders broken. The Markdown renderer rewrites such URLs to
 * `/api/linear-asset/<path>`; this route forwards `<path>` to the Elixir API
 * (`/linear-asset/*path`), which injects the token server-side. The bearer for
 * the Elixir API and the Linear token both stay server-side.
 */
export async function GET(_req: Request, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  if (!Array.isArray(path) || path.length === 0) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }

  const base = process.env.COCKPIT_API_URL;
  if (!base) {
    return NextResponse.json({ error: "COCKPIT_API_URL is not configured" }, { status: 503 });
  }

  const token = process.env.COCKPIT_API_TOKEN;
  const upstream = `${base}/linear-asset/${path.map(encodeURIComponent).join("/")}`;

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
      "cache-control": "private, max-age=300",
    },
  });
}
