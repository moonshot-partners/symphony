import { BoardPayload } from "./contract";
import { MOCK_BOARD } from "./fixtures";

/**
 * Swappable data source behind one interface. Production defaults to `http`
 * so the cockpit follows Symphony as the source of truth. Tests and local dev
 * can still opt into fixtures with `NEXT_PUBLIC_DATA_SOURCE=mock`.
 */
const MODE =
  process.env.NEXT_PUBLIC_DATA_SOURCE ?? (process.env.NODE_ENV === "production" ? "http" : "mock");

export async function fetchBoard(): Promise<BoardPayload> {
  if (MODE === "http") {
    const res = await fetch("/api/board", { cache: "no-store" });
    if (!res.ok) throw new Error(`board fetch failed: ${res.status}`);
    return BoardPayload.parse(await res.json());
  }
  return BoardPayload.parse(MOCK_BOARD);
}
