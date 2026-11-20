import { timingSafeEqual } from 'node:crypto';
import { existsSync, statSync } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { extname, join, normalize, resolve, sep } from 'node:path';
import express, { type NextFunction, type Request, type Response } from 'express';
import {
  RACE_LAPS,
  RUN_TIME_LIMIT_MS,
  TRACKS,
  type JoinCodeResponse,
  type JoinResponse,
  type JoinTicketResponse,
  type ScreenKeyResponse,
  type ServerConfig,
} from '@bitrise-grand-prix/shared';
import { JoinGate } from './joinGate.js';
import { StoreError, type SessionStore } from './store.js';

export interface AppOptions {
  store: SessionStore;
  /** When set, creating, closing and deleting sessions needs `Authorization: Bearer <token>`. */
  adminToken?: string | null;
  /** Explicit URL phones should open, e.g. https://race.example.com. */
  publicUrl?: string | null;
  /** Directory with the built controller site (index.html + assets). */
  controllerDir?: string | null;
  /** Directory with the Godot web export (index.html, .wasm, .pck). */
  gameDir?: string | null;
  /** Issues and checks the QR screen's join codes. */
  joinGate?: JoinGate;
  /** Express "trust proxy" setting, so rate limits see the real client address behind a proxy. */
  trustProxy?: string | boolean | number | null;
  now?: () => number;
}

const PRECOMPRESSED_TYPES: Record<string, string> = {
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.js': 'text/javascript; charset=utf-8',
};

export function firstLanAddress(): string | null {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === 'IPv4' && !address.internal) return address.address;
    }
  }
  return null;
}

function param(req: Request, name: string): string {
  const value = req.params[name];
  return typeof value === 'string' ? value : '';
}

function tokensMatch(expected: string, given: string): boolean {
  const a = Buffer.from(expected);
  const b = Buffer.from(given);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** A fixed-window limit per client address: at most `max` requests per `windowMs`. */
function rateLimit(windowMs: number, max: number, message: string, now: () => number) {
  const hits = new Map<string, { count: number; resetAt: number }>();
  return (req: Request, res: Response, next: NextFunction) => {
    const at = now();
    if (hits.size > 10_000) {
      for (const [key, entry] of hits) if (entry.resetAt <= at) hits.delete(key);
    }
    const key = req.ip ?? 'unknown';
    let entry = hits.get(key);
    if (!entry || entry.resetAt <= at) {
      entry = { count: 0, resetAt: at + windowMs };
      hits.set(key, entry);
    }
    entry.count += 1;
    if (entry.count > max) {
      res.set('Retry-After', String(Math.ceil((entry.resetAt - at) / 1000)));
      res.status(429).json({ error: message });
      return;
    }
    next();
  };
}

// The controller site loads nothing from other origins. The Godot page needs inline script
// (its loader), eval (JavaScriptBridge) and WebAssembly.
const SITE_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  "connect-src 'self' ws: wss:",
  "frame-src 'self'",
  "frame-ancestors 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
].join('; ');
const GAME_CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "connect-src 'self' ws: wss:",
  "worker-src 'self' blob:",
  "frame-ancestors 'self'",
  "object-src 'none'",
  "base-uri 'none'",
].join('; ');

export function createApp(options: AppOptions): express.Express {
  const { store } = options;
  const adminToken = options.adminToken || null;
  const gameDir = options.gameDir ? resolve(options.gameDir) : null;
  const controllerDir = options.controllerDir ? resolve(options.controllerDir) : null;
  const gameAvailable = () => Boolean(gameDir && existsSync(join(gameDir, 'index.html')));

  const now = options.now ?? Date.now;
  const joinGate = options.joinGate ?? new JoinGate({ now });
  const httpsOnly = Boolean(options.publicUrl?.startsWith('https://'));

  const app = express();
  app.disable('x-powered-by');
  if (options.trustProxy !== undefined && options.trustProxy !== null) app.set('trust proxy', options.trustProxy);

  app.use((req, res, next) => {
    res.set({
      'X-Content-Type-Options': 'nosniff',
      // Join links carry a join code; never pass the address on to another site.
      'Referrer-Policy': 'no-referrer',
      'X-Frame-Options': 'SAMEORIGIN',
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Content-Security-Policy': req.path.startsWith('/game') ? GAME_CSP : SITE_CSP,
    });
    if (httpsOnly) res.set('Strict-Transport-Security', 'max-age=15552000');
    next();
  });
  app.use(express.json({ limit: '10kb' }));

  // Guessing the admin token gets slow fast.
  const adminAttempts = rateLimit(10 * 60_000, 30, 'Too many attempts. Wait a few minutes.', now);
  const isAdmin = (req: Request) => {
    if (!adminToken) return true;
    const header = req.get('authorization') ?? '';
    const given = header.startsWith('Bearer ') ? header.slice(7) : '';
    return Boolean(given) && tokensMatch(adminToken, given);
  };
  const requireAdmin = (req: Request, res: Response, next: NextFunction) => {
    if (isAdmin(req)) return next();
    adminAttempts(req, res, () => res.status(401).json({ error: 'The admin token is missing or wrong.' }));
  };
  // The QR screen: the host, or the one device given the session's screen key.
  const requireScreen = (req: Request, res: Response, next: NextFunction) => {
    const session = store.getSession(param(req, 'code'));
    if (isAdmin(req) || (session && store.checkScreenKey(session, req.get('x-screen-key')))) return next();
    adminAttempts(req, res, () => res.status(401).json({ error: 'This screen is not allowed to show join codes.' }));
  };
  const ticketLimit = rateLimit(60_000, 20, 'Too many scans from this device. Wait a minute.', now);
  const joinLimit = rateLimit(60_000, 10, 'Too many joins from this device. Wait a minute.', now);

  // --- API -------------------------------------------------------------------------------------

  app.get('/api/health', (_req, res) => {
    res.json({ ok: true });
  });

  app.get('/api/config', (_req, res) => {
    const config: ServerConfig = {
      authRequired: Boolean(adminToken),
      publicUrl: options.publicUrl || null,
      lanIp: firstLanAddress(),
      raceLaps: RACE_LAPS,
      runTimeLimitMs: RUN_TIME_LIMIT_MS,
      gameAvailable: gameAvailable(),
    };
    res.json(config);
  });

  app.get('/api/tracks', (_req, res) => {
    res.json({ tracks: TRACKS });
  });

  // Lets the controller check a token before it stores it.
  app.get('/api/admin/check', requireAdmin, (_req, res) => {
    res.json({ ok: true });
  });

  app.get('/api/sessions', requireAdmin, (_req, res) => {
    res.json({ sessions: store.listSessions().map((session) => store.toSummary(session)) });
  });

  app.post('/api/sessions', requireAdmin, (req, res) => {
    const body = (req.body ?? {}) as { name?: unknown; trackId?: unknown };
    const session = store.createSession({ name: body.name, trackId: body.trackId });
    res.status(201).json({ session: store.toPublic(session) });
  });

  app.get('/api/sessions/:code', (req, res) => {
    res.json({ session: store.toPublic(store.requireSession(param(req, 'code'))) });
  });

  app.post('/api/sessions/:code/close', requireAdmin, (req, res) => {
    res.json({ session: store.toPublic(store.closeSession(param(req, 'code'))) });
  });

  app.post('/api/sessions/:code/reopen', requireAdmin, (req, res) => {
    res.json({ session: store.toPublic(store.reopenSession(param(req, 'code'))) });
  });

  app.delete('/api/sessions/:code', requireAdmin, (req, res) => {
    store.deleteSession(param(req, 'code'));
    res.status(204).end();
  });

  // A link for the device that will show the QR code, so it needs no admin token.
  app.post('/api/sessions/:code/screen-key', requireAdmin, (req, res) => {
    const response: ScreenKeyResponse = { key: store.createScreenKey(param(req, 'code')) };
    res.status(201).set('Cache-Control', 'no-store').json(response);
  });

  // The QR screen asks for the current join code; only the host (or its QR device) can see it.
  app.get('/api/sessions/:code/join-code', requireScreen, (req, res) => {
    const session = store.requireSession(param(req, 'code'));
    if (session.status !== 'open') throw new StoreError(409, 'This session is closed.');
    const response: JoinCodeResponse = { ...joinGate.issue(session.code), serverNow: now() };
    res.set('Cache-Control', 'no-store').json(response);
  });

  // A phone that scanned the QR code trades the join code for a one-time ticket at once, so the
  // seconds the code lives are not spent typing a name.
  app.post('/api/sessions/:code/tickets', ticketLimit, (req, res) => {
    const session = store.requireSession(param(req, 'code'));
    if (session.status !== 'open') throw new StoreError(409, 'This session is closed.');
    const ticket = joinGate.createTicket(session.code, (req.body as { token?: unknown } | undefined)?.token);
    if (!ticket) throw new StoreError(403, 'This QR code has expired. Scan the code on the screen again.');
    const response: JoinTicketResponse = ticket;
    res.status(201).set('Cache-Control', 'no-store').json(response);
  });

  app.post('/api/sessions/:code/players', joinLimit, (req, res) => {
    const body = (req.body ?? {}) as { name?: unknown; ticket?: unknown };
    const code = param(req, 'code');
    if (!joinGate.checkTicket(code, body.ticket)) {
      throw new StoreError(403, 'Scan the QR code on the screen to join this session.');
    }
    const { player, token } = store.addPlayer(code, body.name);
    joinGate.consumeTicket(body.ticket as string);
    const response: JoinResponse = {
      playerId: player.id,
      token,
      name: player.name,
      color: player.color,
    };
    res.status(201).set('Cache-Control', 'no-store').json(response);
  });

  app.delete('/api/sessions/:code/players/:playerId', requireAdmin, (req, res) => {
    store.removePlayer(param(req, 'code'), param(req, 'playerId'));
    res.status(204).end();
  });

  app.use('/api', (_req, res) => {
    res.status(404).json({ error: 'Not found.' });
  });

  // --- game (Godot web export) -----------------------------------------------------------------

  if (gameDir) {
    // The export script gzips the big files once; serve those instead of compressing per request.
    app.use('/game', (req, res, next) => {
      const type = PRECOMPRESSED_TYPES[extname(req.path)];
      if (!type || !/\bgzip\b/.test(req.get('accept-encoding') ?? '')) return next();
      let file: string;
      try {
        file = normalize(join(gameDir, decodeURIComponent(req.path)));
      } catch {
        return next();
      }
      const zipped = `${file}.gz`;
      if (!file.startsWith(gameDir + sep) || !existsSync(zipped) || !statSync(zipped).isFile()) return next();
      res.set({
        'Content-Encoding': 'gzip',
        'Content-Type': type,
        'Cache-Control': 'no-cache',
        Vary: 'Accept-Encoding',
      });
      res.sendFile(zipped);
    });
    app.use('/game', express.static(gameDir, { setHeaders: (res) => res.set('Cache-Control', 'no-cache') }));
  }
  app.use('/game', (_req, res) => {
    res
      .status(503)
      .type('text/plain')
      .send('The game has not been exported yet. Run "npm run build:game" (needs Godot 4 and its web export templates).');
  });

  // --- controller site -------------------------------------------------------------------------

  if (controllerDir && existsSync(join(controllerDir, 'index.html'))) {
    app.use(express.static(controllerDir, { index: false, maxAge: '1h' }));
    // Single-page app: every other route gets index.html and the router takes it from there.
    app.use((req, res, next) => {
      if (req.method !== 'GET') return next();
      res.set('Cache-Control', 'no-cache').sendFile(join(controllerDir, 'index.html'));
    });
  }

  app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (error instanceof StoreError) {
      res.status(error.status).json({ error: error.message });
      return;
    }
    const status = typeof (error as { status?: unknown })?.status === 'number' ? (error as { status: number }).status : 500;
    if (status >= 500) console.error(error);
    res.status(status).json({ error: status >= 500 ? 'Something went wrong.' : 'Bad request.' });
  });

  return app;
}
