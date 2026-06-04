import { describe, it, expect, vi, afterEach } from "vitest";
import { POST } from "./route";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("POST /api/operations/refresh", () => {
  it("returns 503 when COCKPIT_API_URL is not configured", async () => {
    vi.stubEnv("COCKPIT_API_URL", "");

    const res = await POST();

    expect(res.status).toBe(503);
  });

  it("forwards the bearer token and returns the upstream refresh result", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubEnv("COCKPIT_API_TOKEN", "secret");
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ queued: true }),
    });
    vi.stubGlobal("fetch", fetchMock);

    const res = await POST();

    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ queued: true });
    expect(fetchMock).toHaveBeenCalledWith(
      "http://elixir/refresh",
      expect.objectContaining({
        method: "POST",
        headers: { authorization: "Bearer secret" },
        cache: "no-store",
      })
    );
  });

  it("returns 502 when upstream refresh fails", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 503 }));

    const res = await POST();

    expect(res.status).toBe(502);
  });
});
