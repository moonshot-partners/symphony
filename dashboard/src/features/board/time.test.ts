import { describe, it, expect } from "vitest";
import { formatAgo } from "./time";

describe("formatAgo", () => {
  it("clamps negatives and sub-5s to 'just now'", () => {
    expect(formatAgo(-1000)).toBe("just now");
    expect(formatAgo(0)).toBe("just now");
    expect(formatAgo(4999)).toBe("just now");
  });

  it("formats seconds", () => {
    expect(formatAgo(5000)).toBe("5s ago");
    expect(formatAgo(59_000)).toBe("59s ago");
  });

  it("formats minutes", () => {
    expect(formatAgo(60_000)).toBe("1m ago");
    expect(formatAgo(59 * 60_000)).toBe("59m ago");
  });

  it("formats hours", () => {
    expect(formatAgo(60 * 60_000)).toBe("1h ago");
    expect(formatAgo(23 * 60 * 60_000)).toBe("23h ago");
  });

  it("formats days", () => {
    expect(formatAgo(24 * 60 * 60_000)).toBe("1d ago");
  });
});
