import { LivePayload } from "./contract";
import { MOCK_LIVE } from "./fixtures";

/**
 * Swappable data source, same shape as the board source. Production defaults
 * to `http` so live status follows Symphony as the source of truth. Tests and
 * local dev can still opt into fixtures with `NEXT_PUBLIC_DATA_SOURCE=mock`.
 */
const MODE =
  process.env.NEXT_PUBLIC_DATA_SOURCE ?? (process.env.NODE_ENV === "production" ? "http" : "mock");

export async function fetchLive(): Promise<LivePayload> {
  if (MODE === "http") {
    const res = await fetch("/api/live", { cache: "no-store" });
    if (!res.ok) throw new Error(`live fetch failed: ${res.status}`);
    return LivePayload.parse(await res.json());
  }
  return LivePayload.parse(MOCK_LIVE);
}
