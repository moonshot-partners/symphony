import { describe, it, expect } from "vitest";
import { useState } from "react";
import { render, screen, fireEvent } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Board } from "./board";
import type { Ticket } from "../contract";

// Search state lives in the page shell; the board takes it as a prop. This
// harness wires selection back so card-click → detail works like the real app.
function BoardHarness({ query = "" }: { query?: string }) {
  const [selected, setSelected] = useState<Ticket | null>(null);
  return <Board query={query} selected={selected} onSelect={setSelected} />;
}

function renderBoard(query = "") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <BoardHarness query={query} />
    </QueryClientProvider>,
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

  it("shows only tickets matching the query", async () => {
    renderBoard("avatar");
    expect(await screen.findByText("Vendor profile avatar upload")).toBeInTheDocument();
    expect(screen.queryByText("Fix collection search debounce")).not.toBeInTheDocument();
  });

  it("finds a ticket by its number", async () => {
    renderBoard("933");
    expect(await screen.findByText("Search results pagination")).toBeInTheDocument();
    expect(screen.queryByText("Vendor profile avatar upload")).not.toBeInTheDocument();
  });

  it("shows an empty message when nothing matches", async () => {
    renderBoard("zzzzz");
    expect(await screen.findByText(/no tickets match/i)).toBeInTheDocument();
  });
});
