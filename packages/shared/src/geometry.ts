// The track as the game builds it, for the server's referee and the bots. This mirrors
// game/scripts/track.gd: change one and you must change the other.

import type { TrackFile } from './tracks.js';

export type Vec2 = [x: number, z: number];

export interface Gate {
  pos: Vec2;
  /** Unit driving direction through the gate. */
  dir: Vec2;
  /** Half its width: a car must pass within this distance of `pos`. */
  half: number;
}

export interface TrackGeometry {
  roadHalf: number;
  arena: { halfWidth: number; halfDepth: number };
  /** Sampled centreline, closed. */
  path: Vec2[];
  /** Checkpoints in driving order, then the finish line. */
  gates: Gate[];
  shortcuts: { points: Vec2[]; half: number }[];
  walls: { a: Vec2; b: Vec2; height: number }[];
  boosts: Vec2[];
  /** Where a run starts: a few metres before the finish line. */
  spawn: Vec2;
}

export const SAMPLES_PER_SEGMENT = 12;

/** Catmull-Rom point on the closed centreline; `at` is in control-point units. */
export function pointAt(control: Vec2[], at: number): Vec2 {
  const n = control.length;
  const i = Math.floor(at);
  const t = at - i;
  const p = (k: number) => control[(((i + k) % n) + n) % n]!;
  const [p0, p1, p2, p3] = [p(-1), p(0), p(1), p(2)];
  const t2 = t * t;
  const t3 = t2 * t;
  const axis = (c: 0 | 1) =>
    0.5 * (2 * p1[c] + (-p0[c] + p2[c]) * t + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2 + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3);
  return [axis(0), axis(1)];
}

/** Unit driving direction on the centreline. */
export function tangentAt(control: Vec2[], at: number): Vec2 {
  const n = control.length;
  const i = Math.floor(at);
  const t = at - i;
  const p = (k: number) => control[(((i + k) % n) + n) % n]!;
  const [p0, p1, p2, p3] = [p(-1), p(0), p(1), p(2)];
  const axis = (c: 0 | 1) =>
    0.5 * (-p0[c] + p2[c] + 2 * (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t + 3 * (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t * t);
  const d: Vec2 = [axis(0), axis(1)];
  const length = Math.hypot(d[0], d[1]) || 1;
  return [d[0] / length, d[1] / length];
}

/** The right-hand side of a driving direction; positive offsets in track files go this way. */
export const rightOf = (t: Vec2): Vec2 => [-t[1], t[0]];

const toVec = (point: number[]): Vec2 => [Number(point[0] ?? 0), Number(point[1] ?? 0)];

export function trackGeometry(file: TrackFile): TrackGeometry {
  const control = file.centerline.map(toVec);
  const n = control.length;
  const path: Vec2[] = [];
  for (let i = 0; i < n; i += 1) {
    for (let s = 0; s < SAMPLES_PER_SEGMENT; s += 1) path.push(pointAt(control, i + s / SAMPLES_PER_SEGMENT));
  }
  const roadHalf = file.roadWidth / 2;
  const gateHalf = roadHalf + 4;
  const gateAt = (at: number): Gate => ({ pos: pointAt(control, at), dir: tangentAt(control, at), half: gateHalf });
  const placed = (item: { at: number; offset: number }): Vec2 => {
    const center = pointAt(control, item.at);
    const right = rightOf(tangentAt(control, item.at));
    return [center[0] + right[0] * item.offset, center[1] + right[1] * item.offset];
  };
  return {
    roadHalf,
    arena: file.arena,
    path,
    gates: [...file.checkpoints.map((index) => gateAt(index)), gateAt(0)],
    shortcuts: (file.shortcuts ?? []).map((shortcut) => ({ points: shortcut.points.map(toVec), half: shortcut.width / 2 + 0.4 })),
    walls: (file.walls ?? []).map((wall) => ({ a: toVec(wall.from), b: toVec(wall.to), height: wall.height })),
    boosts: (file.boosts ?? []).map(placed),
    spawn: pointAt(control, n - 0.22),
  };
}

export function segmentDistanceSq(p: Vec2, a: Vec2, b: Vec2): number {
  const abx = b[0] - a[0];
  const abz = b[1] - a[1];
  const lengthSq = abx * abx + abz * abz;
  let t = lengthSq < 1e-4 ? 0 : ((p[0] - a[0]) * abx + (p[1] - a[1]) * abz) / lengthSq;
  t = Math.min(1, Math.max(0, t));
  const dx = p[0] - (a[0] + abx * t);
  const dz = p[1] - (a[1] + abz * t);
  return dx * dx + dz * dz;
}

/** Same rule as the game's track.gd: on the asphalt (plus a little kerb) or a shortcut strip. */
export function isOnRoad(geometry: TrackGeometry, p: Vec2): boolean {
  const limit = geometry.roadHalf + 0.6;
  const limitSq = limit * limit;
  const { path } = geometry;
  for (let i = 0; i < path.length; i += 1) {
    if (segmentDistanceSq(p, path[i]!, path[(i + 1) % path.length]!) <= limitSq) return true;
  }
  for (const shortcut of geometry.shortcuts) {
    for (let i = 0; i < shortcut.points.length - 1; i += 1) {
      if (segmentDistanceSq(p, shortcut.points[i]!, shortcut.points[i + 1]!) <= shortcut.half * shortcut.half) return true;
    }
  }
  return false;
}

/** True when segments p-q and a-b cross. */
export function segmentsCross(p: Vec2, q: Vec2, a: Vec2, b: Vec2): boolean {
  const cross = (o: Vec2, u: Vec2, v: Vec2) => (u[0] - o[0]) * (v[1] - o[1]) - (u[1] - o[1]) * (v[0] - o[0]);
  const d1 = cross(a, b, p);
  const d2 = cross(a, b, q);
  const d3 = cross(p, q, a);
  const d4 = cross(p, q, b);
  return d1 * d2 < 0 && d3 * d4 < 0;
}
