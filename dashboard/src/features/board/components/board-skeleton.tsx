import { Skeleton } from "@/components/ui/skeleton";
import { COLUMNS } from "../bucket";

export function BoardSkeleton() {
  return (
    <div className="flex h-full gap-3 overflow-hidden p-4">
      {COLUMNS.map((col) => (
        <section key={col.key} className="flex min-w-0 flex-1 flex-col">
          <div className="mb-2 flex items-center gap-2 px-1">
            <Skeleton className="h-5 w-20" />
            <Skeleton className="h-5 w-6 rounded-full" />
          </div>
          <div className="flex flex-1 flex-col gap-2 rounded-lg bg-muted/40 p-2">
            {Array.from({ length: 2 }).map((_, i) => (
              <Skeleton
                key={i}
                className="h-24 w-full animate-none rounded-xl skeleton-shimmer"
              />
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
