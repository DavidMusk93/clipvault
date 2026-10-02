import { fileURLToPath, URL } from "node:url";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// The panel iframe is served at /trae/ (by the backend, via the aggregator).
// Assets therefore resolve under /trae/assets/session/. Stable output names
// (no hash) let the thin shell reference them without a manifest fetch; the
// backend serves /trae/* with no-store, so long-term hashing buys little.
//
// `@render` is the shared session DISPLAY LOGIC (web/session-render.mjs): roles,
// alignment, beats-vs-tools, bundles, ask blocks. The React panel renders that
// exact HTML; it must not fork a second implementation.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: "/trae/assets/session/",
  resolve: {
    alias: { "@render": fileURLToPath(new URL("../session-render.mjs", import.meta.url)) },
  },
  server: { fs: { allow: [".."] } },
  build: {
    outDir: "../assets/session",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "app.js",
        chunkFileNames: "chunk-[name].js",
        assetFileNames: "app.[ext]",
      },
    },
  },
});
