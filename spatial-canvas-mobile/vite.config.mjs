import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "./",
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          "vendor-icons": ["@phosphor-icons/react"],
          "vendor-motion": ["motion/react"],
          "vendor-react": ["react", "react-dom/client"],
          "vendor-storage": ["dexie"],
        },
      },
    },
  },
  optimizeDeps: {
    include: ["react", "react-dom/client"],
  },
  server: {
    warmup: {
      clientFiles: ["./src/main.jsx"],
    },
  },
  plugins: [react()],
});
