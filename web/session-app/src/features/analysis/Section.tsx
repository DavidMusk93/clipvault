import type { ReactNode } from "react";
import { cn } from "../../lib/cn";

/** Section frame. Apple HIG grouped list: 24px between groups, a quiet header
 *  (title + one fact on the right) 8px above a white card. */
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
    <section id={id} className={cn("mb-6 scroll-mt-4", className)}>
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
    <div className="mb-2 flex min-h-7 items-center gap-2 px-1">
      <h3 className="text-[15px] font-semibold tracking-[-0.01em] text-ink">{title}</h3>
      {count != null && (
        <span className="text-[13px] font-medium tabular-nums text-role-system">{count}</span>
      )}
      <span className="ml-auto flex items-center gap-2 text-[12px] text-role-system">
        {hint}
        {children}
      </span>
    </div>
  );
}

/** White grouped card. */
export function Card({
  children,
  className,
  id,
}: {
  children: ReactNode;
  className?: string;
  id?: string;
}) {
  return (
    <div
      id={id}
      className={cn("rounded-[14px] border border-black/[0.06] bg-white p-4", className)}
    >
      {children}
    </div>
  );
}

/** Tinted status pill: colour = semantics, always with a word. */
export function Pill({ tone, children }: { tone: string; children: ReactNode }) {
  return (
    <span
      className={cn(
        "inline-flex h-5 shrink-0 items-center rounded-full px-2 text-[11.5px] font-semibold",
        tone,
      )}
    >
      {children}
    </span>
  );
}
