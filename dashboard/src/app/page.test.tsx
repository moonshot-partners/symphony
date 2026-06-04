import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import Home from "./page";

function renderHome() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <Home />
    </QueryClientProvider>,
  );
}

const search = () => screen.getByRole("searchbox", { name: /search tickets/i });

describe("Home (cockpit shell)", () => {
  it("renders the search bar inside the header, next to the brand", async () => {
    renderHome();
    await screen.findByText("Fix collection search debounce");
    const header = search().closest("header");
    expect(header).not.toBeNull();
    expect(header).toHaveTextContent("Symphony");
  });

  it("filters the board when typing in the header search", async () => {
    renderHome();
    await screen.findByText("Fix collection search debounce");
    fireEvent.change(search(), { target: { value: "avatar" } });
    expect(screen.getByText("Vendor profile avatar upload")).toBeInTheDocument();
    expect(screen.queryByText("Fix collection search debounce")).not.toBeInTheDocument();
  });

  it("opens the only match when Enter is pressed in the header search", async () => {
    renderHome();
    await screen.findByText("Fix collection search debounce");
    fireEvent.change(search(), { target: { value: "avatar" } });
    fireEvent.keyDown(search(), { key: "Enter" });
    expect(await screen.findByText("Timeline")).toBeInTheDocument();
  });
});
