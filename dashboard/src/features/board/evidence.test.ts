import { describe, it, expect } from "vitest";
import type { Evidence } from "./contract";
import { groupEvidenceByAc } from "./evidence";

const ev = (id: string, ac: string): Evidence => ({
  id,
  ac,
  kind: "image",
  name: `${id}.png`,
  url: "#",
});

describe("groupEvidenceByAc", () => {
  it("returns an empty list for no evidence", () => {
    expect(groupEvidenceByAc([])).toEqual([]);
  });

  it("groups by AC and preserves first-seen order", () => {
    const groups = groupEvidenceByAc([
      ev("a", "AC 1"),
      ev("b", "AC 1"),
      ev("c", "AC 2"),
      ev("d", "AC 1"),
    ]);
    expect(groups.map((g) => g.ac)).toEqual(["AC 1", "AC 2"]);
    expect(groups[0].items.map((i) => i.id)).toEqual(["a", "b", "d"]);
    expect(groups[1].items.map((i) => i.id)).toEqual(["c"]);
  });

  it("keeps every item exactly once", () => {
    const input = [ev("a", "AC 1"), ev("b", "AC 2"), ev("c", "AC 2")];
    const total = groupEvidenceByAc(input).reduce((n, g) => n + g.items.length, 0);
    expect(total).toBe(input.length);
  });
});
