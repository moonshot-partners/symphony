import type { ComponentProps } from "react";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

export type StatusTone = "neutral" | "success" | "info" | "accent" | "warning" | "danger" | "muted";

const TONE_CLASS: Record<StatusTone, string> = {
  neutral: "border-zinc-200 bg-zinc-50 text-zinc-700",
  success: "border-emerald-200 bg-emerald-50 text-emerald-900",
  info: "border-blue-200 bg-blue-50 text-blue-700",
  accent: "border-violet-200 bg-violet-50 text-violet-700",
  warning: "border-amber-200 bg-amber-50 text-amber-700",
  danger: "border-destructive/20 bg-destructive/10 text-destructive",
  muted: "border-border bg-muted/40 text-foreground",
};

type StatusBadgeProps = ComponentProps<typeof Badge> & {
  tone?: StatusTone;
};

export function StatusBadge({ tone = "neutral", className, variant = "outline", ...props }: StatusBadgeProps) {
  return <Badge variant={variant} className={cn(TONE_CLASS[tone], className)} {...props} />;
}
