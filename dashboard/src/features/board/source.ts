import { BoardPayload } from "./contract";
import { MOCK_BOARD } from "./fixtures";

/**
 * Swappable data source behind one interface. `mock` (default) returns
 * fixtures so the cockpit runs without Hetzner. `http` fetches the BFF route
 * that proxies the Elixir live API. Either way the payload is validated against
 * the Zod contract before it reaches the UI.
 */
const MODE = process.env.NEXT_PUBLIC_DATA_SOURCE ?? "mock";

export async function fetchBoard(): Promise<BoardPayload> {
  if (MODE === "http") {
    const res = await fetch("/api/board", { cache: "no-store" });
    if (!res.ok) throw new Error(`board fetch failed: ${res.status}`);
    return BoardPayload.parse(await res.json());
  }
  return BoardPayload.parse(MOCK_BOARD);
}
