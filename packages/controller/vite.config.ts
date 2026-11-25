import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { gzipSync } from 'node:zlib';
import react from '@vitejs/plugin-react';
import { defineConfig, type Plugin } from 'vite';

// In development the session server runs separately (npm run dev:server) and Vite proxies to it.
const server = process.env.RC_SERVER_URL ?? 'http://localhost:8787';

/**
 * Writes a gzipped copy beside every script and stylesheet the build makes. The session server
 * sends those to browsers that accept gzip (most do), so a phone on venue Wi-Fi downloads about
 * a third as much before the join page can start.
 */
function precompress(): Plugin {
  return {
    name: 'precompress',
    apply: 'build',
    writeBundle(options, bundle) {
      const outDir = options.dir ?? resolve('dist');
      for (const fileName of Object.keys(bundle)) {
        if (!/\.(js|css)$/.test(fileName)) continue;
        const file = resolve(outDir, fileName);
        writeFileSync(`${file}.gz`, gzipSync(readFileSync(file), { level: 9 }));
      }
    },
  };
}

export default defineConfig({
  plugins: [react(), precompress()],
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
