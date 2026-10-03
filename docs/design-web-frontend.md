---
doc_id: clipvault-web-frontend-v1
kind: design
status: active
authority: design
applies_to:
  - web/session-app/**
  - trae_hooks/web/sessions.html
  - web/index.html
  - scripts/deploy-server.sh
  - scripts/check-frontend.sh
  - session/deploy/sync_backend_web.sh
depends_on:
  - AGENTS.md
  - docs/design-taste.md
  - docs/session-analysis.md
supersedes: []
verified_by:
  - scripts/check-frontend.sh
  - web/session-app unit tests (Vitest)
  - Playwright session-panel smoke
---

# Session panel as a real app: React 19 + Radix + ECharts on a Vite build

## 0. Status (2026-10-02)

Landed: P0 (Vite toolchain, deploy-time build), P1 (analysis dashboard),
P2 (keyset pagination + virtualized thread + SSE), P3 (the `/trae/` shell now
mounts the React app; the vanilla panel is kept at
`trae_hooks/web/sessions-vanilla.html` for rollback). `web/index.html` (parent
shell) is unchanged.

## 1. Decision

The session panel stops being a 2 739-line vanilla `sessions.html` with hand-rolled
FSM, DOM patching and chart code. It becomes a **typed React app** built by Vite
at deploy time, served from the same backend web dir as today.

| Layer | Choice | Version (2026-10) |
| --- | --- | --- |
| Language | TypeScript (strict) | 7.0 |
| Build | Vite (MPA/library, content-hashed) | 8.3 |
| Framework | React | 19.3 |
| Routing | TanStack Router (typed) | 1.170 |
| Server state | TanStack Query | 5.104 |
| Client FSM | XState (the panel already has an explicit FSM) | 5.33 |
| Virtualisation | TanStack Virtual | 3.14 |
| Primitives | Radix UI via shadcn/ui (copy-in) | radix 1.1 |
| Styling | Tailwind CSS v4 (CSS-first tokens) | 4.3 |
| Charts | ECharts | 6.1 |
| Contract | Zod (runtime-validate `/api/*`) | 4.6 |
| Tests | Vitest + Testing Library + Playwright | 5.0 / 1.63 |
| Lint/format | Biome | 2.5 |
| Icons | Lucide | 1.50 |

Build is **at deploy time** (`npm ci && vite build`), never committed. The session
panel is the **first app and the template**; the parent shell (`web/index.html`)
stays vanilla until the panel proves the stack.

## 2. Constraints (why the obvious SPA choices do not apply)

| Constraint | Consequence |
| --- | --- |
| The panel is an iframe `/trae/?embed=1` served by the **backend** (d2/cc), not the Mac | Build output must be synced to the backend web dir (`session/deploy/sync_backend_web.sh`), not only to the Mac app. |
| Local/offline, no CDN | Every dep is bundled; no remote fonts/scripts; CSP unchanged. |
| Visual truth is `docs/design-taste.md` | Tokens (Honey `#C47A2C`, role colors) become Tailwind v4 theme variables; components are themed from one source. |
| Existing gates | `scripts/check-frontend.sh` gains `vite build` + `vitest`; existing `node --test` and swiftc/python gates stay. |
| Two-layer scroll, embed postMessage contract | The React app keeps `#sessionList`/`#thread` scrollers and the `clipvault-sessions-*` postMessage handshake. |

## 3. Architecture

```text
   web/session-app/                 (source, committed)
     package.json  vite.config.ts  tsconfig.json  biome.json
     src/
       main.tsx                     mount + providers
       api/                         typed client (Zod) + TanStack Query hooks
       state/                       XState load machine + SSE store
       theme/                       tokens.css  (from design-taste.md)
       components/ui/               shadcn/Radix primitives
       features/session/            rail + virtualized thread
       features/analysis/           /api/mine dashboard (ECharts)
     dist/                          (built, gitignored)
          |
          v  vite build (deploy time)
   web/assets/session/               content-hashed js/css
          |
          v  sync_backend_web.sh
   d2:/root/clipvault/web/assets/session/   (+ cc)

   browser iframe /trae/?embed=1
        |
        v
   trae_hooks/web/sessions.html   (thin shell: tokens + #root + postMessage)
        |
        v
   web/assets/session/main-<hash>.js  (React app)
        |
        v
   /api/sessions /api/events /api/event /api/stream /api/mine  (SA-v1)
```

Data flow: **TanStack Query owns server state** (`/api/sessions`, `/api/events`,
`/api/event`, `/api/mine`), each response parsed through a Zod schema so a Rust
change that breaks the contract fails loudly. **SSE `/api/stream`** feeds a small
normalized store; `hook_event` stubs are appended, bodies stay lazy.

The **load FSM** (`boot → cached → connecting → resync → live`, plus `paused` /
`error`) moves from `session-load.mjs` into an **XState machine**; the React tree
is a pure function of the machine state. This keeps the existing contract
(AGENTS.md · 会话: "加载是显式 FSM，不是一堆 timer") while making it testable.

## 4. Lazy loading and large volume

Two layers, because one is not enough at scale:

```text
   client: O(viewport) DOM
     rail    -> TanStack Virtual (windowed cards)
     thread  -> TanStack Virtual (windowed blocks); bundles expand in place
     bodies  -> IntersectionObserver lazy GET /api/event?id=
     analysis-> route-level dynamic import (not in first paint bundle)

   server: O(page) transfer           (Rust, session/ crate)
     GET /api/events?session_id=&before=&after=&limit=   keyset cursor
     GET /api/sessions?cursor=&limit=                     keyset cursor
     the full tool index becomes paged, not one unbounded payload
```

Today `/api/events` returns the whole tool index for a session ("工具索引必须完整，
禁止 LIMIT 200 砍尾"). That rule stays true **semantically** (the index is
complete and reachable) but becomes **paged**: the client walks cursors as it
virtualises, so completeness is preserved without an O(n) first payload. This is
the one server change this design depends on.

## 5. Template conventions (what the first app establishes)

1. **One app per feature island**, mounted into an existing page; no global SPA
   rewrite. `web/session-app` is the reference.
1b. **Display logic is shared, never forked.** Roles, alignment, beats-vs-tools,
   bundles and ask blocks live in `web/session-render.mjs` (`renderRows`,
   `imMessagesFromEvents`, `focusImRows`, `bundleTitle`, `rowPreview`, …), imported
   by the app as `@render`. The React panel renders that exact HTML; the visual
   identity is `web/session-app/src/theme/panel.css`, copied verbatim from the
   vanilla panel. A rewrite must not invent a second look.
   The shared renderer's engines (marked, DOMPurify, highlight.js) were `<script>`
   globals in vanilla while the app is a bundle: pass them explicitly
   (`web/session-app/src/features/session/engines.ts`), or markdown silently
   degrades to raw text because `renderMarkdownToHtml` refuses to emit unsanitized
   HTML. If the vanilla shell loads a stylesheet directly (e.g. the FAB chrome in
   `/assets/metrics-panel.css`), fold those rules into `panel.css` so the app is
   self-contained.
   The 「分析」sheet is a **component tree**, not shared HTML: `features/analysis/*`
   rebuilds the taste (① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本, semantic
   colour, golden-ratio verdict) with Radix/shadcn primitives + Tailwind tokens +
   ECharts. The old vanilla markup is **not** the spec — the taste is (see
   docs/design-taste.md 「分析」/「布局与节奏」). Charts come from `MineChart`
   (`lib/echarts.ts` `buildMineOption`); the palette/formatters are shared with the
   vanilla rollback via `web/mine-charts.mjs` (aliased `@charts`).
2. **Tokens are code**: `theme/tokens.css` is generated from `docs/design-taste.md`;
   no component hardcodes a hex.
3. **Every API response is Zod-parsed**; the Rust struct and the TS schema are
   reviewed together (later: generate TS from Rust with `ts-rs`).
4. **shadcn/ui primitives** are copied into `components/ui/` and themed; no
   component library runtime is added as a black box.
5. **Charts are declarative wrappers** around ECharts with the design tokens;
   chart kind is declared where the data is built (already the case in `/api/mine`).
   `<MineChart spec>` owns one instance (init / resize / dispose) and skips
   `setOption` when the spec did not change, so a parent re-render never rebuilds
   an unchanged chart.
6. **A11y**: Radix primitives + focus management; the panel is keyboard reachable.
7. **Deploy builds**: `deploy-server.sh` runs the web build; CI runs `vitest`.

## 6. Migration phases

```text
P0  toolchain (no UI change)
    web/session-app scaffold; vite build -> web/assets/session/
    Biome + Vitest wired into check-frontend.sh; deploy-server.sh builds
    sync_backend_web.sh ships the built assets; ?app=0 keeps the vanilla panel

P1  analysis feature (first real slice)
    /api/mine dashboard: typed client + TanStack Query + shadcn cards/tables +
    ECharts (metrics / losses / findings). Mounted behind ?app=1; A/B vs vanilla.

P2  session panel
    rail + virtualized thread + XState SSE store; server keyset pagination
    default ?app=1; vanilla sheet retired after parity

P3  shell (optional)
    evaluate migrating web/index.html; decide per island, not wholesale
```

Rollback: every phase ships behind `?app=` / a build flag; the vanilla panel is
kept until parity is proven.

## 7. Gates and evidence

| Gate | Command |
| --- | --- |
| Types + lint | `biome check` + `tsc --noEmit` |
| Unit | `vitest run` (api schemas, FSM transitions, virtual window math) |
| Build | `vite build` in `check-frontend.sh` |
| Panel smoke | Playwright: open `/trae/?embed=1`, assert rail cards + thread + analysis, no console errors |
| Existing | `node --test tests/*.test.mjs`, swiftc + python gates unchanged |

## 8. Open items

| ID | Item | Needed before |
| --- | --- | --- |
| `W-1` | Keyset pagination contract for `/api/events` and `/api/sessions` (cursor shape, `before`/`after`, stable order key). | P2 |
| `W-2` | Zod schema vs `ts-rs`-generated types from the Rust structs (single source of truth). | P1 |
| `W-3` | Bundle budget for the first paint of the iframe (target to be set after P1 measures). | P1 |
| `W-4` | Whether the parent shell migrates at all (P3). | P3 |
