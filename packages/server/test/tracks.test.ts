import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  isOnRoad,
  pointAt,
  RACE_LAPS,
  rightOf,
  tangentAt,
  TRACK_FILES,
  trackGeometry,
  type TrackFile,
  type Vec2,
} from '@bitrise-grand-prix/shared';

// The rules every track file has to follow, so a new or edited track cannot quietly break them.

const tracksDir = fileURLToPath(new URL('../../../game/tracks/', import.meta.url));

describe('track files', () => {
  it('are all offered, each under its own file name', () => {
    const files = readdirSync(tracksDir).filter((name) => name.endsWith('.json'));
    const ids = files.map((name) => (JSON.parse(readFileSync(tracksDir + name, 'utf8')) as TrackFile).id);
    expect(ids).toEqual(files.map((name) => name.replace(/\.json$/, '')));
    expect(TRACK_FILES.map((track) => track.id).sort()).toEqual([...ids].sort());
  });
});

describe.each(TRACK_FILES.map((track) => [track.name, track] as const))('%s', (_name, track) => {
  const geometry = trackGeometry(track);
  const control = track.centerline.map((point): Vec2 => [point[0] ?? 0, point[1] ?? 0]);
  const placed = (item: { at: number; offset: number }): Vec2 => {
    const centre = pointAt(control, item.at);
    const right = rightOf(tangentAt(control, item.at));
    return [centre[0] + right[0] * item.offset, centre[1] + right[1] * item.offset];
  };
  const rampMiddles = (track.ramps ?? []).map((ramp): Vec2 => {
    const heading = (ramp.headingDeg * Math.PI) / 180;
    return [
      (ramp.pos[0] ?? 0) + (Math.cos(heading) * ramp.length) / 2,
      (ramp.pos[1] ?? 0) + (Math.sin(heading) * ramp.length) / 2,
    ];
  });

  it('has a time limit that leaves room for a slow run', () => {
    expect(track.timeLimitMs).toBeGreaterThanOrEqual(60_000);
    expect(track.timeLimitMs).toBeLessThanOrEqual(180_000);
    expect(track.timeLimitMs).toBeGreaterThan(RACE_LAPS * track.minLapMs * 2);
  });

  it('has at least two ramps, each on the road or a shortcut', () => {
    expect(rampMiddles.length).toBeGreaterThanOrEqual(2);
    for (const middle of rampMiddles) {
      expect(isOnRoad(geometry, middle), `ramp at ${middle.join(', ')}`).toBe(true);
    }
  });

  it('keeps boosts well away from the ramps', () => {
    for (const item of track.boosts ?? []) {
      const [x, z] = placed(item);
      for (const [rx, rz] of rampMiddles) {
        expect(Math.hypot(x - rx, z - rz), `boost at ${item.at}`).toBeGreaterThan(20);
      }
    }
  });

  it('puts every boost and bug on the road', () => {
    for (const item of [...(track.boosts ?? []), ...(track.obstacles ?? [])]) {
      expect(Math.abs(item.offset), `box at ${item.at}`).toBeLessThan(track.roadWidth / 2);
      expect(isOnRoad(geometry, placed(item)), `box at ${item.at}`).toBe(true);
    }
  });

  it('has checkpoints on its control points, in driving order', () => {
    expect(track.checkpoints.length).toBeGreaterThanOrEqual(2);
    expect([...track.checkpoints].sort((a, b) => a - b)).toEqual(track.checkpoints);
    for (const index of track.checkpoints) {
      expect(index).toBeGreaterThan(0);
      expect(index).toBeLessThan(control.length);
    }
  });

  it('keeps the road inside the arena', () => {
    for (const [x, z] of geometry.path) {
      expect(Math.abs(x) + geometry.roadHalf).toBeLessThan(track.arena.halfWidth - 6);
      expect(Math.abs(z) + geometry.roadHalf).toBeLessThan(track.arena.halfDepth - 6);
    }
  });
});
