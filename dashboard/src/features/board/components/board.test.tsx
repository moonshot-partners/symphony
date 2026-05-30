import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Board } from "./board";

function renderBoard() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <Board />
    </QueryClientProvider>
  );
}

describe("Board", () => {
  it("renders every lifecycle column once the mock data loads", async () => {
    renderBoard();
    await screen.findByText("Fix collection search debounce");
    for (const label of [
      "Up next",
      "In progress",
      "Being reviewed",
      "Ready to ship",
      "Needs attention",
      "Done",
    ]) {
      expect(screen.getByText(label)).toBeInTheDocument();
    }
  });

  it("places the running ticket in progress with a Working badge", async () => {
    renderBoard();
    await screen.findByText("Fix collection search debounce");
    expect(screen.getByText("Working")).toBeInTheDocument();
  });

  it("opens the ticket detail when a card is clicked", async () => {
    renderBoard();
    const card = await screen.findByText("Fix collection search debounce");
    fireEvent.click(card);
    expect(await screen.findByText("Timeline")).toBeInTheDocument();
    expect(screen.getByText(/Evidence \(/)).toBeInTheDocument();
  });
});
