import { createServer } from 'node:http';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp, firstLanAddress } from './app.js';
import { RealtimeHub } from './realtime.js';
import { SessionStore } from './store.js';

// Works both from src/ (tsx) and from dist/ (bundled): either way the package root is one up.
const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(packageRoot, '../..');

const port = Number(process.env.PORT) || 8787;
const dataDir = process.env.DATA_DIR ?? resolve(repoRoot, 'data');
const persist = process.env.PERSIST !== 'false';

const adminToken = process.env.ADMIN_TOKEN || null;
const publicUrl = process.env.PUBLIC_URL?.replace(/\/+$/, '') || null;

// Without an admin token anyone can open the QR screen, and so join from anywhere. Fine on a
// laptop at a booth; not on a public deployment.
if (!adminToken && process.env.NODE_ENV === 'production' && process.env.ALLOW_NO_ADMIN_TOKEN !== 'true') {
  console.error('ADMIN_TOKEN must be set in production (or set ALLOW_NO_ADMIN_TOKEN=true to run without one).');
  process.exit(1);
}
if (adminToken && adminToken.length < 16) {
  console.warn('ADMIN_TOKEN is short; use at least 16 random characters.');
}

const trustProxyEnv = process.env.TRUST_PROXY;
const trustProxy = trustProxyEnv === undefined ? null : trustProxyEnv === 'true' ? true : /^\d+$/.test(trustProxyEnv) ? Number(trustProxyEnv) : trustProxyEnv;

const store = new SessionStore({ persistPath: persist ? resolve(dataDir, 'sessions.json') : null });
const app = createApp({
  store,
  adminToken,
  publicUrl,
  trustProxy,
  controllerDir: process.env.CONTROLLER_DIR ?? resolve(repoRoot, 'packages/controller/dist'),
  gameDir: process.env.GAME_DIR ?? resolve(repoRoot, 'game/export/web'),
});

const server = createServer(app);
const hub = new RealtimeHub(store, publicUrl);
hub.attach(server);

server.listen(port, () => {
  const lan = firstLanAddress();
  console.log(`Bitrise Grand Prix server listening on http://localhost:${port}`);
  if (lan) console.log(`On this network:               http://${lan}:${port}`);
  if (!adminToken) {
    console.log('ADMIN_TOKEN is not set: anyone who can reach this server can manage sessions and open the QR screen.');
  }
});

function shutdown() {
  store.flush();
  hub.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
