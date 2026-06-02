"use client";

import { useEffect, useRef } from "react";
import { Search, X } from "lucide-react";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

/**
 * The board's search bar. Filtering happens in place over the already-loaded
 * tickets (see filter.ts), so the operator keeps the lifecycle context — a
 * match stays in its column — instead of being dropped onto a results page.
 * Keyboard-first to match the trackers it mirrors: "/" jumps in, Esc clears.
 */
export function SearchBar({
  value,
  onChange,
  onClear,
  onSubmit,
  resultCount,
  className,
}: {
  value: string;
  onChange: (value: string) => void;
  onClear: () => void;
  onSubmit?: () => void;
  resultCount?: number;
  className?: string;
}) {
  const ref = useRef<HTMLInputElement>(null);

  // Press "/" anywhere to focus search (the GitHub/Linear pattern), unless the
  // user is already typing in a field — then "/" is a literal character.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "/" || e.defaultPrevented) return;
      const el = e.target as HTMLElement | null;
      const tag = el?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el?.isContentEditable) {
        return;
      }
      e.preventDefault();
      ref.current?.focus();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  const hasQuery = value.trim() !== "";

  return (
    <div className={cn("flex items-center gap-2", className)}>
      <div role="search" className="relative w-full max-w-xs">
        <Search
          className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        <Input
          ref={ref}
          type="search"
          aria-label="Search tickets by number or title"
          placeholder="Search tickets…"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              onClear();
              e.currentTarget.blur();
            } else if (e.key === "Enter") {
              onSubmit?.();
            }
          }}
          className="px-8 [&::-webkit-search-cancel-button]:hidden"
        />
        {hasQuery && (
          <button
            type="button"
            aria-label="Clear search"
            onClick={() => {
              onClear();
              ref.current?.focus();
            }}
            className="absolute top-1/2 right-1.5 flex size-5 -translate-y-1/2 items-center justify-center rounded-md text-muted-foreground outline-none transition-colors hover:text-foreground focus-visible:ring-3 focus-visible:ring-ring/50"
          >
            <X className="size-3.5" aria-hidden />
          </button>
        )}
      </div>
      {hasQuery && resultCount !== undefined && (
        <span
          className="shrink-0 text-xs text-muted-foreground tabular-nums"
          aria-live="polite"
          role="status"
        >
          {resultCount === 0
            ? "No matches"
            : `${resultCount} result${resultCount === 1 ? "" : "s"}`}
        </span>
      )}
    </div>
  );
}
