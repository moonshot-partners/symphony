import { describe, it, expect, vi, afterEach } from "vitest";
import { MOCK_LIVE } from "./fixtures";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("fetchLive — http adapter", () => {
  it("fetches the BFF route with no-store and validates in http mode", async () => {
    vi.stubEnv("NEXT_PUBLIC_DATA_SOURCE", "http");
    vi.resetModules();
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => MOCK_LIVE });
    vi.stubGlobal("fetch", fetchMock);

    const { fetchLive } = await import("./source");
    const live = await fetchLive();

    expect(live.agents).toHaveLength(MOCK_LIVE.agents.length);
    expect(live.available).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/live",
      expect.objectContaining({ cache: "no-store" }),
    );
  });

  it("throws when the BFF responds with an error", async () => {
    vi.stubEnv("NEXT_PUBLIC_DATA_SOURCE", "http");
    vi.resetModules();
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 502 }));

    const { fetchLive } = await import("./source");
    await expect(fetchLive()).rejects.toThrow(/502/);
  });

  it("returns the mock snapshot in mock mode without fetching", async () => {
    vi.stubEnv("NEXT_PUBLIC_DATA_SOURCE", "mock");
    vi.resetModules();
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const { fetchLive } = await import("./source");
    const live = await fetchLive();

    expect(live.agents[0].id).toBe("SODEV-956");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
