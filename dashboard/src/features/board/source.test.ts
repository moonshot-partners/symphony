import { describe, it, expect } from "vitest";
import { fetchBoard } from "./source";
import { MOCK_BOARD } from "./fixtures";

describe("fetchBoard (mock source)", () => {
  it("returns a contract-validated board with every ticket", async () => {
    const board = await fetchBoard();
    expect(board.tickets).toHaveLength(MOCK_BOARD.tickets.length);
    expect(board.tickets.every((t) => typeof t.id === "string")).toBe(true);
    expect(board.states.active).toContain("Todo");
  });
});
