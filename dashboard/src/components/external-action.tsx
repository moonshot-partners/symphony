import type { LucideIcon } from "lucide-react";
import { ExternalLink } from "lucide-react";
import type { ComponentProps } from "react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";

type ExternalActionProps = Omit<ComponentProps<"a">, "target" | "rel"> & {
  icon: LucideIcon;
  label: string;
};

export function ExternalAction({
  icon: Icon,
  label,
  className,
  children,
  ...props
}: ExternalActionProps) {
  return (
    <a
      aria-label={`${label} (opens in a new tab)`}
      target="_blank"
      rel="noopener noreferrer"
      className={cn(buttonVariants({ variant: "outline", size: "sm" }), "h-8", className)}
      {...props}
    >
      <Icon className="size-3.5" aria-hidden />
      {children}
      <ExternalLink className="size-3 text-muted-foreground" aria-hidden />
    </a>
  );
}
