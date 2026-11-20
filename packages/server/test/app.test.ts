import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { DEFAULT_TRACK_ID } from '@bitrise-grand-prix/shared';
import { createApp } from '../src/app.js';
import { SessionStore } from '../src/store.js';

const ADMIN = 'test-admin-token-123456';
const servers: { close: () => void }[] = [];

afterEach(() => {
  while (servers.length) servers.pop()!.close();
});

async function start(adminToken: string | null = ADMIN) {
  let clock = 1_700_000_000_000;
  const store = new SessionStore({ now: () => clock });
  const session = store.createSession({ name: 'Booth', trackId: DEFAULT_TRACK_ID });
  const app = createApp({ store, adminToken, now: () => clock });
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
