// Fake players for trying out the big screen and ghost cars without a room full of phones.
//
//   ADMIN_TOKEN=... npm run bots --workspace @bitrise-grand-prix/server -- <SESSION_CODE> [count] [serverUrl]
//
// Each bot joins the way a phone does (a join code from the QR screen, traded for a ticket;
// the bots get the code with the admin token, like the QR screen), then follows the track
// centreline lap after lap, reporting its position. The server's referee times the laps.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import {
  RACE_LAPS,
  type JoinCodeResponse,
  type JoinResponse,
  type JoinTicketResponse,
  type PublicSession,
  type ServerMessage,
} from '@bitrise-grand-prix/shared';

const [code, countArg, urlArg] = process.argv.slice(2);
if (!code) {
  console.error('Usage: npm run bots --workspace @bitrise-grand-prix/server -- <SESSION_CODE> [count] [serverUrl]');
  process.exit(1);
}
const count = Number(countArg) || 4;
const baseUrl = (urlArg ?? 'http://localhost:8787').replace(/\/+$/, '');
const adminHeaders: Record<string, string> = process.env.ADMIN_TOKEN ? { authorization: `Bearer ${process.env.ADMIN_TOKEN}` } : {};

const NAMES = ['Bitbot', 'Flaky Fred', 'Cache Money', 'YAML Yoda', 'Null Ptr', 'Sudo Sue', 'Merge Marge', 'Green Gus'];
const SAMPLES_PER_SEGMENT = 12;
const TICK_MS = 100;

type Point = [number, number];

function catmullRom(p0: Point, p1: Point, p2: Point, p3: Point, t: number): Point {
  const t2 = t * t;
  const t3 = t2 * t;
  const axis = (i: 0 | 1) =>
    0.5 * (2 * p1[i] + (-p0[i] + p2[i]) * t + (2 * p0[i] - 5 * p1[i] + 4 * p2[i] - p3[i]) * t2 + (-p0[i] + 3 * p1[i] - 3 * p2[i] + p3[i]) * t3);
  return [axis(0), axis(1)];
}

function samplePath(control: Point[]): Point[] {
  const n = control.length;
  const at = (i: number) => control[((i % n) + n) % n]!;
  const path: Point[] = [];
  for (let i = 0; i < n; i += 1) {
    for (let s = 0; s < SAMPLES_PER_SEGMENT; s += 1) {
      path.push(catmullRom(at(i - 1), at(i), at(i + 1), at(i + 2), s / SAMPLES_PER_SEGMENT));
    }
  }
  return path;
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`);
  return (await response.json()) as T;
}

async function runBot(index: number, path: Point[]) {
  const codeResponse = await fetch(`${baseUrl}/api/sessions/${code}/join-code`, { headers: adminHeaders });
  if (!codeResponse.ok) throw new Error(`join code: ${codeResponse.status} (set ADMIN_TOKEN if the server has one)`);
  const { token } = (await codeResponse.json()) as JoinCodeResponse;
  const { ticket } = await post<JoinTicketResponse>(`/api/sessions/${code}/tickets`, { token });
  const joined = await fetch(`${baseUrl}/api/sessions/${code}/players`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: NAMES[index % NAMES.length], ticket }),
  });
  if (!joined.ok) throw new Error(`join failed: ${joined.status} ${await joined.text()}`);
  const me = (await joined.json()) as JoinResponse;

  const ws = new WebSocket(`${baseUrl.replace(/^http/, 'ws')}/ws?session=${code}&role=player&token=${me.token}`);
  const send = (message: object) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(message));

  ws.on('message', (data) => {
    const message = JSON.parse(data.toString()) as ServerMessage;
    if (message.t === 'run_result') {
      console.log(`${me.name}: ${message.accepted ? `rank ${message.rank}, ${message.result?.totalMs} ms` : `rejected (${message.reason})`}`);
    }
    if (message.t === 'closed' || message.t === 'removed') ws.close();
  });
  await new Promise<void>((done, fail) => {
    ws.once('open', () => done());
    ws.once('error', fail);
  });

  const lateral = (index % 3) - 1; // spread the bots across the road
  while (ws.readyState === WebSocket.OPEN) {
    // Below the car's top speed of 26, so the referee has nothing to complain about.
    const speed = 17 + Math.random() * 7;
    send({ t: 'run_start' });
    const runStart = Date.now();
    let distance = 0;
    let lap = 1;
    // Start on the grid, a few samples before the finish line, like a real car.
    let segment = path.length - 3;
    let along = 0;

    while (lap <= RACE_LAPS && ws.readyState === WebSocket.OPEN) {
      await new Promise((done) => setTimeout(done, TICK_MS));
      distance = speed * (TICK_MS / 1000);
      while (distance > 0) {
        const a = path[segment]!;
        const b = path[(segment + 1) % path.length]!;
        const length = Math.hypot(b[0] - a[0], b[1] - a[1]);
        if (along + distance < length) {
          along += distance;
          distance = 0;
        } else {
          distance -= length - along;
          along = 0;
          segment = (segment + 1) % path.length;
          // Over the line; the very first crossing is just leaving the grid.
          if (segment === 0 && Date.now() - runStart > 3000) lap += 1;
        }
      }
      const a = path[segment]!;
      const b = path[(segment + 1) % path.length]!;
      const heading = Math.atan2(b[1] - a[1], b[0] - a[0]);
      const t = along / Math.max(0.001, Math.hypot(b[0] - a[0], b[1] - a[1]));
      const x = a[0] + (b[0] - a[0]) * t - Math.sin(heading) * lateral * 2.5;
      const z = a[1] + (b[1] - a[1]) * t + Math.cos(heading) * lateral * 2.5;
      send({ t: 'pos', p: [x, 0.5, z, heading], ct: Date.now() - runStart, fx: 0 });
    }

    send({ t: 'run_finish', finished: true });
    await new Promise((done) => setTimeout(done, 3000 + Math.random() * 4000));
  }
}

const sessionResponse = await fetch(`${baseUrl}/api/sessions/${code}`);
if (!sessionResponse.ok) {
  console.error(`Session ${code} not found on ${baseUrl}.`);
  process.exit(1);
}
const { session } = (await sessionResponse.json()) as { session: PublicSession };

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const track = JSON.parse(readFileSync(resolve(repoRoot, 'game/tracks', `${session.trackId}.json`), 'utf8')) as {
  centerline: Point[];
};
const path = samplePath(track.centerline);

console.log(`Sending ${count} bots to "${session.name}" (${code}) on ${baseUrl}. Ctrl+C to stop.`);
await Promise.all(
  Array.from({ length: count }, (_, index) =>
    runBot(index, path).catch((error) => console.error(`bot ${index}:`, error.message)),
  ),
);
