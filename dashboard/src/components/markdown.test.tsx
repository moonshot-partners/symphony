import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { Markdown } from "./markdown";

describe("Markdown", () => {
  it("renders headings as real heading elements, not raw ## text", () => {
    const { container } = render(<Markdown>{"## Ready for review\n\nbody"}</Markdown>);
    const heading = container.querySelector("h1, h2, h3, h4, h5, h6");
    expect(heading).not.toBeNull();
    expect(heading!.textContent).toBe("Ready for review");
    // the literal markdown marker must not survive
    expect(screen.queryByText("## Ready for review")).toBeNull();
  });

  it("renders bold as <strong>, not literal asterisks", () => {
    const { container } = render(<Markdown>{"**Outcome:** shipped"}</Markdown>);
    const strong = container.querySelector("strong");
    expect(strong).not.toBeNull();
    expect(strong!.textContent).toBe("Outcome:");
    expect(container.textContent).not.toContain("**");
  });

  it("renders a GFM pipe table as a real <table> with cells", () => {
    const md = "| Check | Result |\n| --- | --- |\n| no loading flicker | PASS |\n";
    const { container } = render(<Markdown>{md}</Markdown>);
    expect(container.querySelector("table")).not.toBeNull();
    const cells = Array.from(container.querySelectorAll("td")).map((c) => c.textContent);
    expect(cells).toContain("no loading flicker");
    expect(cells).toContain("PASS");
    // no leftover pipe characters from the raw source
    expect(container.textContent).not.toContain("|");
  });

  it("renders links as new-tab anchors with safe rel", () => {
    const md = "See [SODEV-969](https://linear.app/schools-out/issue/SODEV-969).";
    const { container } = render(<Markdown>{md}</Markdown>);
    const link = container.querySelector("a");
    expect(link).not.toBeNull();
    expect(link!.getAttribute("href")).toBe("https://linear.app/schools-out/issue/SODEV-969");
    expect(link!.getAttribute("target")).toBe("_blank");
    expect(link!.getAttribute("rel")).toContain("noopener");
    expect(link!.textContent).toBe("SODEV-969");
  });

  it("renders inline code as <code> without backticks", () => {
    const { container } = render(<Markdown>{"Moved to `In Code Review` after"}</Markdown>);
    const code = container.querySelector("code");
    expect(code).not.toBeNull();
    expect(code!.textContent).toBe("In Code Review");
    expect(container.textContent).not.toContain("`");
  });

  it("renders bullet lists as <li> items", () => {
    const { container } = render(<Markdown>{"- Result: PASS\n- second item"}</Markdown>);
    const items = Array.from(container.querySelectorAll("li")).map((i) => i.textContent);
    expect(items).toEqual(["Result: PASS", "second item"]);
  });

  it("strips embedded HTML/script to prevent XSS", () => {
    const md = "before <script>window.__xss=1</script> after <img src=x onerror=alert(1)>";
    const { container } = render(<Markdown>{md}</Markdown>);
    expect(container.querySelector("script")).toBeNull();
    const img = container.querySelector("img");
    // sanitize must drop the event handler even if an img survives
    expect(img?.getAttribute("onerror") ?? null).toBeNull();
  });

  it("rewrites Linear upload images to the same-origin asset proxy", () => {
    const md = "![Screenshot](https://uploads.linear.app/ws-id/dir-id/file-id)";
    const { container } = render(<Markdown>{md}</Markdown>);
    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    // the raw uploads.linear.app URL 401s in a browser; it must be proxied
    expect(img!.getAttribute("src")).toBe("/api/linear-asset/ws-id/dir-id/file-id");
    expect(img!.getAttribute("alt")).toBe("Screenshot");
  });

  it("leaves non-Linear image sources untouched", () => {
    const md = "![logo](https://example.com/logo.png)";
    const { container } = render(<Markdown>{md}</Markdown>);
    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    expect(img!.getAttribute("src")).toBe("https://example.com/logo.png");
  });

  it("trims surrounding whitespace", () => {
    const { container } = render(<Markdown>{"\n\n  hello  \n\n"}</Markdown>);
    expect(container.textContent?.trim()).toBe("hello");
  });
});
