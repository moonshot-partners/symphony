import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import { BoardSkeleton } from "./board-skeleton";
import { COLUMNS } from "../bucket";

describe("BoardSkeleton", () => {
  it("renders one placeholder column per lifecycle stage", () => {
    const { container } = render(<BoardSkeleton />);
    expect(container.querySelectorAll("section")).toHaveLength(COLUMNS.length);
  });
});
