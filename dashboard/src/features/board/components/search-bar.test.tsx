import { describe, it, expect } from "vitest";
import { useState } from "react";
import { render, screen, fireEvent } from "@testing-library/react";
import { SearchBar } from "./search-bar";

function Harness({
  initial = "",
  resultCount,
}: {
  initial?: string;
  resultCount?: number;
}) {
  const [value, setValue] = useState(initial);
  const [submits, setSubmits] = useState(0);
  return (
    <>
      <SearchBar
        value={value}
        onChange={setValue}
        onClear={() => setValue("")}
        onSubmit={() => setSubmits((n) => n + 1)}
        resultCount={resultCount}
      />
      <output data-testid="value">{value}</output>
      <output data-testid="submits">{submits}</output>
    </>
  );
}

const input = () => screen.getByRole("searchbox", { name: /search tickets/i });

describe("SearchBar", () => {
  it("renders an accessible search input", () => {
    render(<Harness />);
    expect(input()).toBeInTheDocument();
  });

  it("reports typed text through onChange", () => {
    render(<Harness />);
    fireEvent.change(input(), { target: { value: "956" } });
    expect(screen.getByTestId("value")).toHaveTextContent("956");
  });

  it("hides the clear button when empty and shows it once there is text", () => {
    render(<Harness />);
    expect(screen.queryByRole("button", { name: /clear/i })).not.toBeInTheDocument();
    fireEvent.change(input(), { target: { value: "avatar" } });
    expect(screen.getByRole("button", { name: /clear/i })).toBeInTheDocument();
  });

  it("clears the query when the clear button is clicked", () => {
    render(<Harness initial="avatar" />);
    fireEvent.click(screen.getByRole("button", { name: /clear/i }));
    expect(screen.getByTestId("value")).toHaveTextContent("");
  });

  it("clears the query when Escape is pressed", () => {
    render(<Harness initial="avatar" />);
    fireEvent.keyDown(input(), { key: "Escape" });
    expect(screen.getByTestId("value")).toHaveTextContent("");
  });

  it("submits when Enter is pressed", () => {
    render(<Harness initial="956" />);
    fireEvent.keyDown(input(), { key: "Enter" });
    expect(screen.getByTestId("submits")).toHaveTextContent("1");
  });

  it("focuses the input when '/' is pressed anywhere on the page", () => {
    render(<Harness />);
    expect(input()).not.toHaveFocus();
    fireEvent.keyDown(document.body, { key: "/" });
    expect(input()).toHaveFocus();
  });

  it("does not hijack '/' while another field is being typed in", () => {
    render(
      <>
        <input data-testid="other" />
        <Harness />
      </>,
    );
    const other = screen.getByTestId("other");
    other.focus();
    fireEvent.keyDown(other, { key: "/" });
    expect(input()).not.toHaveFocus();
    expect(other).toHaveFocus();
  });

  it("announces the number of matches while searching", () => {
    render(<Harness initial="search" resultCount={3} />);
    expect(screen.getByText(/3 results/i)).toBeInTheDocument();
  });

  it("uses the singular form for a single match", () => {
    render(<Harness initial="956" resultCount={1} />);
    expect(screen.getByText(/1 result\b/i)).toBeInTheDocument();
  });

  it("says when nothing matches", () => {
    render(<Harness initial="zzz" resultCount={0} />);
    expect(screen.getByText(/no matches/i)).toBeInTheDocument();
  });

  it("shows no count when the query is empty", () => {
    render(<Harness resultCount={6} />);
    expect(screen.queryByText(/results?/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/no matches/i)).not.toBeInTheDocument();
  });
});
