import { describe, it, expect } from "vitest";
import { render, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { LiveStatus } from "./live-status";

describe("LiveStatus", () => {
  it("renders the tenant label and resolves to a live state", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const { container } = render(
      <QueryClientProvider client={client}>
        <LiveStatus />
      </QueryClientProvider>
    );
    expect(container.textContent).toContain("schools-out");
    await waitFor(() => expect(container.textContent).toMatch(/schools-out · live/));
  });
});
