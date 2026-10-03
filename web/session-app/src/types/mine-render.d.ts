// Types for the shared session-analysis display logic (web/mine-render.mjs),
// aliased as `@mine`. Keep this in sync with the module's exports.
declare module "@mine" {
  export type MineSections = {
    nav: string;
    verdict: string;
    losses: string;
    timeline: string;
    ledger: string;
  };
  export function mineSections(data: unknown, opts?: { openTurn?: number | null }): MineSections;
  export function mineBodyHtml(data: unknown, opts?: { openTurn?: number | null }): string;
  export function mineSummaryHtml(data: unknown): string;
  export function mineDirectionsHtml(directions: unknown[], selected?: string[]): string;
  export function mineDataSig(data: unknown): string;
  export function mineDraftMarkdown(data: unknown): string;
  export function mineSpan(v: unknown): string;
  export function mineUsd(v: unknown): string;
}
