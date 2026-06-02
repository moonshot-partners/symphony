import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { PipelineRail } from "./pipeline-rail";

describe("PipelineRail", () => {
  it("renders every happy-path phase as an ordered list", () => {
    render(<PipelineRail current="running" />);
    const rail = screen.getByRole("list", { name: /pipeline position/i });
    for (const label of ["Queued", "Working", "Review", "Staging", "Done"]) {
      expect(rail).toHaveTextContent(label);
    }
    expect(screen.getAllByRole("listitem")).toHaveLength(5);
  });

  it("marks the current phase active and earlier phases not", () => {
    render(<PipelineRail current="running" />);
    expect(screen.getByText("Working").className).toContain("text-emerald-700");
    expect(screen.getByText("Queued").className).not.toContain("text-emerald-700");
  });
});
