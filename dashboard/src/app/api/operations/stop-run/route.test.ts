import { describe, it, expect, vi, afterEach } from "vitest";
import { POST } from "./route";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

function req(body: unknown) {
  return new Request("http://localhost/api/operations/stop-run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("POST /api/operations/stop-run", () => {
  it("returns 503 when COCKPIT_API_URL is not configured", async () => {
    vi.stubEnv("COCKPIT_API_URL", "");

    const res = await POST(req({ issueId: "uuid-956" }));

    expect(res.status).toBe(503);
  });

  it("requires issueId", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");

    const res = await POST(req({}));

    expect(res.status).toBe(400);
  });

  it("forwards the stop request to the cockpit API", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubEnv("COCKPIT_API_TOKEN", "secret");
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ stopped: true, issue_id: "uuid-956" }),
    });
    vi.stubGlobal("fetch", fetchMock);

    const res = await POST(req({ issueId: "uuid-956" }));

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ stopped: true, issue_id: "uuid-956" });
    expect(fetchMock).toHaveBeenCalledWith(
      "http://elixir/runs/uuid-956/stop",
      expect.objectContaining({
        method: "POST",
        headers: { authorization: "Bearer secret" },
        cache: "no-store",
      })
    );
  });

  it("preserves the upstream not_running status", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 404 }));

    const res = await POST(req({ issueId: "uuid-956" }));

    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_running" });
  });
});
