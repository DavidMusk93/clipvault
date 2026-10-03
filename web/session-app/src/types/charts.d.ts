// Types for the shared chart palette / formatters (web/mine-charts.mjs),
// aliased as `@charts`.
declare module "@charts" {
  export const CHART_PALETTE: string[];
  export const PHASE_COLORS: Record<string, string>;
  export const SEV_COLORS: Record<string, string>;
  export function colorAt(i: number): string;
  export function fmtValue(v: unknown, unit?: string, digits?: number): string;
  export function fmtCompact(v: unknown, digits?: number): string;
}
