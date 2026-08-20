import { defineConfig } from "vite";

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        index: "index.html",
        waiting: "waiting.html",
        dashboard: "dashboard.html",
        admin: "admin.html"
      }
    }
  }
});
