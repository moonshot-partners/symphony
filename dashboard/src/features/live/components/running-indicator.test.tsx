import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";

const useLiveMock = vi.fn();
vi.mock("../use-live", () => ({ useLive: () => useLiveMock() }));

import { RunningIndicator } from "./running-indicator";

beforeEach(() => useLiveMock.mockReset());

describe("RunningIndicator", () => {
  it("shows the count of running agents", () => {
    useLiveMock.mockReturnValue({ data: { agents: [{}, {}, {}] } });
    render(<RunningIndicator />);
    expect(screen.getByText(/3 working/)).toBeInTheDocument();
  });

  it("renders nothing when no agent is running", () => {
    useLiveMock.mockReturnValue({ data: { agents: [] } });
    const { container } = render(<RunningIndicator />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing before the first live response", () => {
    useLiveMock.mockReturnValue({ data: undefined });
    const { container } = render(<RunningIndicator />);
    expect(container).toBeEmptyDOMElement();
  });
});
