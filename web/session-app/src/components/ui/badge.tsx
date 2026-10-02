import type { HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

const SEV: Record<string, string> = {
  high: "bg-mine-loss/12 text-mine-loss",
  med: "bg-honey/12 text-honey",
  note: "bg-role-system/12 text-role-system",
  good: "bg-emerald-600/12 text-emerald-700",
};

export function Badge({
  className,
  sev,
  ...props
}: HTMLAttributes<HTMLSpanElement> & { sev?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold",
        sev ? SEV[sev] || SEV.note : "bg-black/5 text-role-system",
        className,
      )}
      {...props}
    />
  );
}
