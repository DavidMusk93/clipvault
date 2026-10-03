import type { ReactNode } from "react";
import { cn } from "../../lib/cn";

/** Section frame: ① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本. */
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
    <section id={id} className={cn("mb-3.5 scroll-mt-11", className)}>
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
    <div className="mb-2 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.04em] text-role-system">
      <span>{title}</span>
      {count != null && (
        <span className="rounded-full bg-black/10 px-1.5 text-[10px] leading-[18px] tabular-nums">
          {count}
        </span>
      )}
      <span className="ml-auto flex items-center gap-2 text-[11px] font-medium normal-case tracking-normal">
        {hint}
        {children}
      </span>
    </div>
  );
}
