import type { ReactNode } from "react";
import { cn } from "../../lib/cn";

/** Section frame: ① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本.
 *  Apple HIG: 24px between groups, 12px section-header → content. */
export function Section({
  id,
  children,
  className,
}: {
  id: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section id={id} className={cn("mb-6 scroll-mt-12", className)}>
      {children}
    </section>
  );
}

export function SectionHead({
  title,
  count,
  hint,
  children,
}: {
  title: string;
  count?: number;
  hint?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className="mb-3 flex items-center gap-2">
      <h3 className="text-[13px] font-semibold tracking-[-0.01em] text-ink">{title}</h3>
      {count != null && (
        <span className="rounded-full bg-black/[0.07] px-2 py-0.5 text-[11px] font-medium tabular-nums text-role-system">
          {count}
        </span>
      )}
      <span className="ml-auto flex items-center gap-2 text-[12px] text-role-system">
        {hint}
        {children}
      </span>
    </div>
  );
}
