import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { MOCK_BOARD } from "@/features/board/fixtures";
import { GET, __resetBoardCache } from "./route";

beforeEach(() => {
  __resetBoardCache();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("GET /api/board (BFF)", () => {
  it("returns 503 when COCKPIT_API_URL is not configured", async () => {
    vi.stubEnv("COCKPIT_API_URL", "");
    const res = await GET();
    expect(res.status).toBe(503);
  });

  it("returns 502 when the upstream responds with an error", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 500 }));
    const res = await GET();
    expect(res.status).toBe(502);
  });

  it("returns 502 when the upstream is unreachable", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("ECONNREFUSED")));
    const res = await GET();
    expect(res.status).toBe(502);
  });

  it("returns 502 when the payload breaks the contract", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, json: async () => ({ bad: true }) }));
    const res = await GET();
    expect(res.status).toBe(502);
  });

  it("returns 200 with the validated board and forwards the bearer token", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    vi.stubEnv("COCKPIT_API_TOKEN", "secret");
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => MOCK_BOARD });
    vi.stubGlobal("fetch", fetchMock);

    const res = await GET();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.tickets).toHaveLength(6);
    expect(fetchMock).toHaveBeenCalledWith(
      "http://elixir/board",
      expect.objectContaining({ headers: { authorization: "Bearer secret" } })
    );
  });

  it("serves a cached snapshot within the TTL (one upstream fetch for repeat calls)", async () => {
    vi.stubEnv("COCKPIT_API_URL", "http://elixir");
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => MOCK_BOARD });
    vi.stubGlobal("fetch", fetchMock);

    const first = await GET();
    const second = await GET();

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
