import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';
import { findTrackFile, type ServerMessage } from '@bitrise-grand-prix/shared';
import { RealtimeHub } from '../src/realtime.js';
import { setup } from './drive.js';

const running: { hub: RealtimeHub; server: Server }[] = [];

afterEach(async () => {
  for (const { hub, server } of running.splice(0)) {
    hub.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

/** A session server on a free port, with one open session. */
async function listen() {
  const ctx = setup();
  const server = createServer();
  const hub = new RealtimeHub(ctx.store);
  hub.attach(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  running.push({ hub, server });
  const { port } = server.address() as AddressInfo;
  const socketUrl = (query: string) => `ws://127.0.0.1:${port}/ws?session=${ctx.session.code}${query}`;
  return { ctx, socketUrl };
}

/** Connects and returns the first message the server sends. */
function firstMessage(url: string): Promise<ServerMessage> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.once('message', (data) => {
      resolve(JSON.parse(String(data)) as ServerMessage);
      ws.close();
    });
    ws.once('error', reject);
  });
}

describe('the welcome message', () => {
  it("gives the game the referee's own copy of the track", async () => {
    const { ctx, socketUrl } = await listen();
    const { token } = ctx.store.addPlayer(ctx.session.code, 'Ada');

    const welcome = await firstMessage(socketUrl(`&role=player&token=${token}`));

    // The game builds the track from this copy, so a game exported before or after a track edit
    // still has every boost box where the referee expects one: a box it doesn't know about makes
    // an honest run look faster than the car can go.
    expect(welcome.t).toBe('welcome');
    expect(welcome.t === 'welcome' && welcome.track).toEqual(JSON.parse(JSON.stringify(findTrackFile(ctx.session.trackId))));
  });

  it('gives the big screen the track too, but not the site', async () => {
    const { ctx, socketUrl } = await listen();

    const spectator = await firstMessage(socketUrl('&role=spectator'));
    const watcher = await firstMessage(socketUrl(''));

    expect(spectator).toMatchObject({ t: 'welcome', track: { id: ctx.session.trackId } });
    expect(watcher.t).toBe('welcome');
    expect(watcher).not.toHaveProperty('track');
  });
});
