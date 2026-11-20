// Test helpers: a fake clock and a car that drives the default track's centreline, reporting
// its position ten times a second like the game does.

import { DEFAULT_TRACK_ID, findTrack, findTrackFile, trackGeometry, type Vec2 } from '@bitrise-grand-prix/shared';
import { SessionStore, type Player, type Session } from '../src/store.js';

export const track = findTrack(DEFAULT_TRACK_ID)!;
export const geometry = trackGeometry(findTrackFile(DEFAULT_TRACK_ID)!);
export const gatesPerLap = track.checkpoints + 1;

// The run starts on the grid, a few samples before the finish line; distances are measured from there.
const START = geometry.path.length - 3;
const loop: Vec2[] = [...geometry.path.slice(START), ...geometry.path.slice(0, START)];
const cumulative: number[] = [0];
for (let i = 1; i <= loop.length; i += 1) {
  const a = loop[i - 1]!;
  const b = loop[i % loop.length]!;
  cumulative.push(cumulative[i - 1]! + Math.hypot(b[0] - a[0], b[1] - a[1]));
}
/** One lap of the centreline. */
export const lapLength = cumulative[loop.length]!;
/** From the grid to the finish line. */
export const toLine = cumulative[3]!;

/** Point and heading `distance` along the centreline from the grid, lap after lap. */
export function along(distance: number): { x: number; z: number; heading: number } {
  const d = ((distance % lapLength) + lapLength) % lapLength;
  let i = 0;
  while (cumulative[i + 1]! < d) i += 1;
  const a = loop[i]!;
  const b = loop[(i + 1) % loop.length]!;
  const t = (d - cumulative[i]!) / Math.max(1e-6, cumulative[i + 1]! - cumulative[i]!);
  return { x: a[0] + (b[0] - a[0]) * t, z: a[1] + (b[1] - a[1]) * t, heading: Math.atan2(b[1] - a[1], b[0] - a[0]) };
}

export function setup(options: { persistPath?: string | null } = {}) {
  let clock = 1_000_000;
  const store = new SessionStore({ now: () => clock, persistPath: options.persistPath ?? null });
  const session = store.createSession({ name: 'Booth', trackId: DEFAULT_TRACK_ID });
  return {
    store,
    session,
    now: () => clock,
    advance: (ms: number) => {
      clock += ms;
    },
  };
}

export type Context = ReturnType<typeof setup>;

export const join = (ctx: Context, name: string, session: Session = ctx.session) => ctx.store.addPlayer(session.code, name).player;

/** A run in progress: drive it a stretch at a time. */
export function startRun(ctx: Context, player: Player, session: Session = ctx.session) {
  const startedAt = ctx.store.startRun(session, player);
  let distance = 0;
  const pose = (x: number, z: number, heading: number, y = 0.5, ctShift = 0) =>
    ctx.store.recordPose(session, player, [x, y, z, heading], ctx.now() - startedAt + ctShift);
  return {
    get distance() {
      return distance;
    },
    /** Follows the centreline at `speed` m/s for `metres`, one sample every 100 ms. */
    drive(speed: number, metres: number) {
      const end = distance + metres;
      while (distance < end) {
        ctx.advance(100);
        distance = Math.min(end, distance + speed * 0.1);
        const at = along(distance);
        pose(at.x, at.z, at.heading);
      }
    },
    /** Drives straight to `target` at `speed`, wherever that leads (grass, walls). */
    straightTo(target: Vec2, speed: number) {
      const start = along(distance);
      let x = start.x;
      let z = start.z;
      for (;;) {
        const dx = target[0] - x;
        const dz = target[1] - z;
        const left = Math.hypot(dx, dz);
        if (left < 0.01) break;
        const step = Math.min(left, speed * 0.1);
        x += (dx / left) * step;
        z += (dz / left) * step;
        ctx.advance(100);
        pose(x, z, Math.atan2(dz, dx));
      }
    },
    pose,
    finish: (finished = true) => ctx.store.finishRun(session, player, { finished }),
  };
}

/** Drives a full, honest run at `speed` and finishes it. */
export function driveRun(ctx: Context, player: Player, speed: number, laps = 3) {
  const run = startRun(ctx, player);
  run.drive(speed, toLine + lapLength * laps + 2);
  return run.finish(laps >= 3);
}
