import { LivePayload } from "./contract";
import { MOCK_LIVE } from "./fixtures";

/**
 * Swappable data source, same shape as the board source. `mock` (default)
 * returns fixtures so the cockpit runs without Hetzner. `http` fetches the BFF
 * route that proxies the Elixir `/live` API. Either way the payload is
 * validated against the Zod contract before it reaches the UI.
 */
const MODE = process.env.NEXT_PUBLIC_DATA_SOURCE ?? "mock";

export async function fetchLive(): Promise<LivePayload> {
  if (MODE === "http") {
    const res = await fetch("/api/live", { cache: "no-store" });
    if (!res.ok) throw new Error(`live fetch failed: ${res.status}`);
    return LivePayload.parse(await res.json());
  }
  return LivePayload.parse(MOCK_LIVE);
}
