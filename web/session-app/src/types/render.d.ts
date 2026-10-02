// Types for the shared session display logic (web/session-render.mjs), aliased
// as `@render`. Keep this in sync with the module's exports.
declare module "@render" {
  export interface ImRow {
    role: string;
    label: string;
    align: string;
    event: Record<string, unknown>;
  }
  export type LayoutItem =
    | { type: "focus"; row: ImRow }
    | { type: "bundle"; rows: ImRow[]; title: string };

  export function imMessagesFromEvents(events: unknown[]): ImRow[];
  export function focusImRows(rows: ImRow[]): LayoutItem[];
  export function layoutImRows(rows: ImRow[]): LayoutItem[];
  export function layoutKey(item: LayoutItem): string;
  export function bundleTitle(rows: ImRow[]): string;
  export function rowPreview(row: ImRow): string;
  export function localDateTime(ts: unknown): string;
  export function relLocalTime(ts: unknown, nowMs?: number): string;
  export function recencyTone(ts: unknown, nowMs?: number): string;
  export function volumeBand(n: unknown): string;
  export function renderRows(rows: ImRow[], prev: ImRow | null, engines?: unknown): string;
  export function isAskTool(e: unknown): boolean;
  export function asObj(v: unknown): Record<string, unknown> | null;
  export function esc(s: unknown): string;
}
