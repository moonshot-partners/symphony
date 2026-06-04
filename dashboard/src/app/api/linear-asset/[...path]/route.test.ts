import { describe, it, expect, vi, afterEach } from "vitest";
import { GET } from "./route";

const ctx = (path: string[]) => ({ params: Promise.resolve({ path }) });

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("GET /api/linear-asset/[...path]", () => {
  it("proxies the asset and forwards the upstream content-type", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://api.internal");
    vi.stubEnv("COCKPIT_API_TOKEN", "secret");
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(new Uint8Array([1, 2, 3]), {
        status: 200,
        headers: { "content-type": "image/png" },
      })
    );
    vi.stubGlobal("fetch", fetchMock);

    const res = await GET(new Request("http://x"), ctx(["ws-id", "dir-id", "file-id"]));

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
    expect(fetchMock).toHaveBeenCalledWith(
      "http://api.internal/linear-asset/ws-id/dir-id/file-id",
      expect.objectContaining({ headers: { authorization: "Bearer secret" } })
    );
  });

  it("404s when the path is empty", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://api.internal");
    expect((await GET(new Request("http://x"), ctx([]))).status).toBe(404);
  });

  it("503s when COCKPIT_API_URL is not configured", async () => {
    vi.stubEnv("COCKPIT_API_URL", "");
    const res = await GET(new Request("http://x"), ctx(["ws-id", "dir-id", "file-id"]));
    expect(res.status).toBe(503);
  });

  it("404s when the upstream asset is missing", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://api.internal");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("", { status: 404 })));

    const res = await GET(new Request("http://x"), ctx(["ws-id", "dir-id", "absent"]));
    expect(res.status).toBe(404);
  });

  it("502s when the upstream is unreachable", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://api.internal");
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("boom")));

    const res = await GET(new Request("http://x"), ctx(["ws-id", "dir-id", "file-id"]));
    expect(res.status).toBe(502);
  });
});
