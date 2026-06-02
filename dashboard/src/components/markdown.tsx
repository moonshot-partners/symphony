import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeSanitize from "rehype-sanitize";

/**
 * Renders trusted-ish markdown (Linear issue descriptions, agent run summaries,
 * QA reports) as real HTML instead of raw text. The content originates from
 * humans and from agent output, so rehype-sanitize strips any embedded HTML and
 * event handlers before render. Styling maps onto the existing design tokens
 * rather than @tailwindcss/typography, which is too generous with spacing for a
 * dense detail panel.
 */

const components: Components = {
  h1: ({ children }) => (
    <h3 className="mt-4 mb-2 text-sm font-semibold first:mt-0">{children}</h3>
  ),
  h2: ({ children }) => (
    <h4 className="mt-4 mb-2 text-sm font-semibold first:mt-0">{children}</h4>
  ),
  h3: ({ children }) => (
    <h5 className="mt-3 mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground first:mt-0">
      {children}
    </h5>
  ),
  h4: ({ children }) => (
    <h6 className="mt-3 mb-1.5 text-xs font-semibold first:mt-0">{children}</h6>
  ),
  p: ({ children }) => (
    <p className="my-2 text-sm leading-relaxed first:mt-0 last:mb-0">{children}</p>
  ),
  a: ({ href, children }) => (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="font-medium text-foreground underline decoration-muted-foreground/40 underline-offset-2 transition-colors hover:decoration-foreground"
    >
      {children}
    </a>
  ),
  ul: ({ children }) => (
    <ul className="my-2 list-disc space-y-1 pl-5 text-sm leading-relaxed first:mt-0 last:mb-0">
      {children}
    </ul>
  ),
  ol: ({ children }) => (
    <ol className="my-2 list-decimal space-y-1 pl-5 text-sm leading-relaxed first:mt-0 last:mb-0">
      {children}
    </ol>
  ),
  li: ({ children }) => <li className="leading-relaxed">{children}</li>,
  code: ({ className, children }) => {
    const isBlock = /language-/.test(className ?? "");
    if (isBlock) return <code className={className}>{children}</code>;
    return (
      <code className="rounded bg-muted px-1 py-0.5 font-mono text-[0.85em]">
        {children}
      </code>
    );
  },
  pre: ({ children }) => (
    <pre className="my-2 overflow-x-auto rounded-md border bg-muted/40 p-3 font-mono text-xs leading-relaxed first:mt-0 last:mb-0">
      {children}
    </pre>
  ),
  table: ({ children }) => (
    <div className="my-2 overflow-x-auto first:mt-0 last:mb-0">
      <table className="w-full border-collapse text-sm">{children}</table>
    </div>
  ),
  th: ({ children }) => (
    <th className="border-b px-2 py-1.5 text-left text-xs font-medium text-muted-foreground">
      {children}
    </th>
  ),
  td: ({ children }) => (
    <td className="border-b px-2 py-1.5 align-top">{children}</td>
  ),
  strong: ({ children }) => (
    <strong className="font-semibold text-foreground">{children}</strong>
  ),
  blockquote: ({ children }) => (
    <blockquote className="my-2 border-l-2 pl-3 text-muted-foreground">
      {children}
    </blockquote>
  ),
  hr: () => <hr className="my-3 border-border" />,
};

export function Markdown({ children }: { children: string }) {
  return (
    <div className="text-foreground">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[rehypeSanitize]}
        components={components}
      >
        {children.trim()}
      </ReactMarkdown>
    </div>
  );
}
