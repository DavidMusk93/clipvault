import DOMPurify from "dompurify";
import hljs from "highlight.js/lib/common";
import { marked } from "marked";

/**
 * Rendering engines for the shared display logic (`web/session-render.mjs`).
 *
 * The vanilla panel loaded marked / DOMPurify / highlight.js as `<script>`
 * globals. The React app is a bundled module, so those globals do not exist;
 * `renderMarkdownToHtml` then refuses to emit HTML (it must never inject
 * unsanitized library output) and every bubble silently degrades to raw text.
 * Bundling the engines keeps markdown/code rendering identical and offline
 * (no CDN).
 */
export const ENGINES = { marked, purify: DOMPurify, hljs } as const;
