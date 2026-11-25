import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { afterEach, describe, expect, it } from 'vitest';
import { DEFAULT_TRACK_ID } from '@bitrise-grand-prix/shared';
import { createApp, type AppOptions } from '../src/app.js';
import { SessionStore } from '../src/store.js';

const ADMIN = 'test-admin-token-123456';
const servers: { close: () => void }[] = [];
const folders: string[] = [];

afterEach(() => {
  while (servers.length) servers.pop()!.close();
  while (folders.length) rmSync(folders.pop()!, { recursive: true, force: true });
});

/** A stand-in for the built controller site: its page, and a script with a gzipped copy. */
function fakeSite(): string {
  const dir = mkdtempSync(join(tmpdir(), 'grand-prix-site-'));
  folders.push(dir);
  writeFileSync(join(dir, 'index.html'), '<!doctype html><title>site</title>');
  mkdirSync(join(dir, 'assets'));
  const script = 'console.log("hello from the site");'.repeat(50);
  writeFileSync(join(dir, 'assets', 'app.js'), script);
  writeFileSync(join(dir, 'assets', 'app.js.gz'), gzipSync(script));
  return dir;
}

async function start(adminToken: string | null = ADMIN, extra: Partial<AppOptions> = {}) {
  let clock = 1_700_000_000_000;
  const store = new SessionStore({ now: () => clock });
  const session = store.createSession({ name: 'Booth', trackId: DEFAULT_TRACK_ID });
  const app = createApp({ store, adminToken, now: () => clock, ...extra });
  const server = app.listen(0);
  servers.push(server);
  await new Promise((done) => server.once('listening', done));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const call = (path: string, init: RequestInit & { admin?: boolean } = {}) =>
    fetch(base + path, {
      ...init,
      headers: {
        'content-type': 'application/json',
        ...(init.admin ? { authorization: `Bearer ${ADMIN}` } : {}),
        ...(init.headers as Record<string, string> | undefined),
      },
    });
  const post = (path: string, body: unknown) => call(path, { method: 'POST', body: JSON.stringify(body) });
  return {
    session,
    call,
    post,
    advance: (ms: number) => {
      clock += ms;
    },
    joinCode: async () => ((await (await call(`/api/sessions/${session.code}/join-code`, { admin: true })).json()) as { token: string }).token,
  };
}

describe('joining', () => {
  it('only the host can see the join code', async () => {
    const { session, call } = await start();
    expect((await call(`/api/sessions/${session.code}/join-code`)).status).toBe(401);
    expect((await call(`/api/sessions/${session.code}/join-code`, { admin: true })).status).toBe(200);
  });

  it('refuses a join without a ticket, or with a made-up one', async () => {
    const { session, post } = await start();
    expect((await post(`/api/sessions/${session.code}/players`, { name: 'Mallory' })).status).toBe(403);
    expect((await post(`/api/sessions/${session.code}/players`, { name: 'Mallory', ticket: 'abc' })).status).toBe(403);
    expect((await post(`/api/sessions/${session.code}/tickets`, { token: 'abc.def' })).status).toBe(403);
  });

  it('lets a phone that scanned a fresh code join, once', async () => {
    const { session, post, joinCode } = await start();
    const ticketResponse = await post(`/api/sessions/${session.code}/tickets`, { token: await joinCode() });
    expect(ticketResponse.status).toBe(201);
    const { ticket } = (await ticketResponse.json()) as { ticket: string };

    const joined = await post(`/api/sessions/${session.code}/players`, { name: 'Ada', ticket });
    expect(joined.status).toBe(201);
    expect(await joined.json()).toMatchObject({ name: 'Ada', token: expect.any(String) });
    expect((await post(`/api/sessions/${session.code}/players`, { name: 'Ada again', ticket })).status).toBe(403);
  });

  it('refuses a code that is more than ten seconds old', async () => {
    const { session, post, joinCode, advance } = await start();
    const token = await joinCode();
    advance(10_000);
    expect((await post(`/api/sessions/${session.code}/tickets`, { token })).status).toBe(403);
  });

  it('slows down a device that scans over and over', async () => {
    const { session, post } = await start();
    const statuses: number[] = [];
    for (let i = 0; i < 22; i += 1) statuses.push((await post(`/api/sessions/${session.code}/tickets`, { token: 'x' })).status);
    expect(statuses.at(-1)).toBe(429);
  });
});

describe('joining on a slow phone', () => {
  it("trades a scanned code on the phone's first request, before the site loads", async () => {
    const { session, call, post, joinCode, advance } = await start(ADMIN, { controllerDir: fakeSite() });
    const opened = await call(`/join/${session.code}?t=${encodeURIComponent(await joinCode())}`, { redirect: 'manual' });
    expect(opened.status).toBe(303);
    expect(opened.headers.get('cache-control')).toBe('no-store');
    const location = opened.headers.get('location') ?? '';
    expect(location).toMatch(new RegExp(`^/join/${session.code}#ticket=[\\w-]+&until=\\d+$`));

    // Long after the code itself has run out, the ticket still lets them in, once.
    advance(60_000);
    const ticket = decodeURIComponent(/ticket=([^&]+)/.exec(location)![1]!);
    expect((await post(`/api/sessions/${session.code}/players`, { name: 'Slow Sam', ticket })).status).toBe(201);
    expect((await post(`/api/sessions/${session.code}/players`, { name: 'Again', ticket })).status).toBe(403);
  });

  it('sends a scan that arrives too late to the "expired" message', async () => {
    const { session, call, joinCode, advance } = await start(ADMIN, { controllerDir: fakeSite() });
    const token = await joinCode();
    advance(10_000);
    const opened = await call(`/join/${session.code}?t=${encodeURIComponent(token)}`, { redirect: 'manual' });
    expect(opened.status).toBe(303);
    expect(opened.headers.get('location')).toBe(`/join/${session.code}#expired`);
  });

  it('leaves a closed session, or a page opened without a code, to the site', async () => {
    const { session, call, joinCode } = await start(ADMIN, { controllerDir: fakeSite() });
    expect((await call(`/join/${session.code}`, { redirect: 'manual' })).status).toBe(200);
    const token = await joinCode();
    await call(`/api/sessions/${session.code}/close`, { method: 'POST', admin: true });
    const opened = await call(`/join/${session.code}?t=${encodeURIComponent(token)}`, { redirect: 'manual' });
    expect(opened.status).toBe(200);
    expect(await opened.text()).toContain('<title>site</title>');
  });

  it("sends the site's scripts gzipped to browsers that accept it", async () => {
    const { call } = await start(ADMIN, { controllerDir: fakeSite() });
    const zipped = await call('/assets/app.js', { headers: { 'accept-encoding': 'gzip' } });
    expect(zipped.status).toBe(200);
    expect(zipped.headers.get('content-encoding')).toBe('gzip');
    expect(zipped.headers.get('content-type')).toContain('text/javascript');
    expect(zipped.headers.get('vary')).toContain('Accept-Encoding');
    expect(await zipped.text()).toContain('hello from the site');

    const plain = await call('/assets/app.js', { headers: { 'accept-encoding': 'identity' } });
    expect(plain.headers.get('content-encoding')).toBeNull();
    expect(plain.headers.get('vary')).toContain('Accept-Encoding');
  });
});

describe('the QR screen on another device', () => {
  it('a screen key shows join codes for its session and nothing else', async () => {
    const { session, call } = await start();
    const created = await call(`/api/sessions/${session.code}/screen-key`, { method: 'POST', admin: true });
    expect(created.status).toBe(201);
    const { key } = (await created.json()) as { key: string };
    const asScreen = (path: string, init: RequestInit = {}) =>
      call(path, { ...init, headers: { 'x-screen-key': key } } as RequestInit);

    const code = await asScreen(`/api/sessions/${session.code}/join-code`);
    expect(code.status).toBe(200);
    expect(await code.json()).toMatchObject({ token: expect.any(String), rotatesAt: expect.any(Number) });
    expect((await asScreen('/api/sessions')).status).toBe(401);
    expect((await asScreen(`/api/sessions/${session.code}/close`, { method: 'POST' })).status).toBe(401);
    expect((await asScreen(`/api/sessions/${session.code}/screen-key`, { method: 'POST' })).status).toBe(401);
  });

  it('a new screen key cancels the old one, and only the host can make one', async () => {
    const { session, call } = await start();
    expect((await call(`/api/sessions/${session.code}/screen-key`, { method: 'POST' })).status).toBe(401);
    const make = async () =>
      ((await (await call(`/api/sessions/${session.code}/screen-key`, { method: 'POST', admin: true })).json()) as { key: string }).key;
    const first = await make();
    const second = await make();
    const fetchCode = (key: string) => call(`/api/sessions/${session.code}/join-code`, { headers: { 'x-screen-key': key } } as RequestInit);
    expect((await fetchCode(first)).status).toBe(401);
    expect((await fetchCode(second)).status).toBe(200);
  });
});

describe('admin', () => {
  it('locks session management behind the token when one is set', async () => {
    const { session, call } = await start();
    expect((await call('/api/sessions')).status).toBe(401);
    expect((await call(`/api/sessions/${session.code}/close`, { method: 'POST' })).status).toBe(401);
    expect((await call('/api/sessions', { admin: true })).status).toBe(200);
  });

  it('slows down guessing the token', async () => {
    const { call } = await start();
    let status = 0;
    for (let i = 0; i < 32; i += 1) {
      status = (await call('/api/admin/check', { headers: { authorization: 'Bearer wrong' } })).status;
    }
    expect(status).toBe(429);
  });
});

describe('headers', () => {
  it('sends security headers and keeps join codes out of referrers', async () => {
    const { call } = await start();
    const response = await call('/api/config');
    expect(response.headers.get('referrer-policy')).toBe('no-referrer');
    expect(response.headers.get('x-content-type-options')).toBe('nosniff');
    expect(response.headers.get('content-security-policy')).toContain("frame-ancestors 'self'");
    expect(response.headers.get('x-powered-by')).toBeNull();
  });
});
