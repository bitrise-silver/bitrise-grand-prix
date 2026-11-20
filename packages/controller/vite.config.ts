import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// In development the session server runs separately (npm run dev:server) and Vite proxies to it.
const server = process.env.RC_SERVER_URL ?? 'http://localhost:8787';

export default defineConfig({
  plugins: [react()],
  server: {
    // Listen on the LAN too, so a phone can open the QR code during development.
    host: true,
    port: 5173,
    proxy: {
      '/api': server,
      '/game': server,
      '/ws': { target: server, ws: true },
    },
  },
});
