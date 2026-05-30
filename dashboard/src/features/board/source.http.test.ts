import { describe, it, expect, vi, afterEach } from "vitest";
import { MOCK_BOARD } from "./fixtures";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("fetchBoard — http adapter", () => {
  it("fetches the BFF route and validates in http mode", async () => {
    vi.stubEnv("NEXT_PUBLIC_DATA_SOURCE", "http");
    vi.resetModules();
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => MOCK_BOARD });
    vi.stubGlobal("fetch", fetchMock);

    const { fetchBoard } = await import("./source");
    const board = await fetchBoard();

    expect(board.tickets).toHaveLength(6);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/board",
      expect.objectContaining({ cache: "no-store" })
    );
  });

  it("throws when the BFF responds with an error", async () => {
    vi.stubEnv("NEXT_PUBLIC_DATA_SOURCE", "http");
    vi.resetModules();
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 500 }));

    const { fetchBoard } = await import("./source");
    await expect(fetchBoard()).rejects.toThrow(/500/);
  });
});
