import { describe, it, expect } from "vitest";
import { fetchBoard } from "./source";

describe("fetchBoard (mock source)", () => {
  it("returns a contract-validated board with every ticket", async () => {
    const board = await fetchBoard();
    expect(board.tickets).toHaveLength(6);
    expect(board.tickets.every((t) => typeof t.id === "string")).toBe(true);
    expect(board.states.active).toContain("Todo");
  });
});
