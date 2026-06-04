import { Card, CardContent, CardDescription, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

export function MetricCard({
  label,
  value,
  className,
}: {
  label: string;
  value: string;
  className?: string;
}) {
  return (
    <Card size="sm" className={cn("gap-1 rounded-lg py-2", className)}>
      <CardContent className="px-2">
        <CardDescription className="text-[10px] uppercase tracking-wide">{label}</CardDescription>
        <CardTitle className="mt-0.5 truncate font-mono text-xs">{value}</CardTitle>
      </CardContent>
    </Card>
  );
}
