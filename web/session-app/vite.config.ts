import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// The panel iframe is served at /trae/ (by the backend, via the aggregator).
// Assets therefore resolve under /trae/assets/session/. Stable output names
// (no hash) let the thin shell reference them without a manifest fetch; the
// backend serves /trae/* with no-store, so long-term hashing buys little.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: "/trae/assets/session/",
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
