import {
  CAR_BOOST_FACTOR,
  CAR_EFFECT_MS,
  CAR_GRASS_FACTOR,
  CAR_MAX_SPEED,
  isOnRoad,
  segmentDistanceSq,
  segmentsCross,
  type TrackGeometry,
  type Vec2,
} from '@bitrise-grand-prix/shared';

// The referee watches one run through the positions the phone reports and decides, on the
// server's own clock, when checkpoints and laps happen. It also checks that the car could
// really have moved that way: no faster than the car's top speed (more only right after a
// boost box, less on grass), no jumps across the map, no driving through walls, and a phone
// clock that does not run ahead of real time.
//
// That does not make cheating impossible: a bot that drives a perfect line at full speed
// stays inside every limit. It does rule out typed-in times, teleports, speed hacks and
// cutting across the grass, which are the cheap ways.

/** A sample can be this far ahead of the server's clock: a network stall can hold back the start message. */
const CLOCK_AHEAD_MS = 2000;
/** Speed is judged over this much of the phone's time, which smooths out uneven samples. */
const WINDOW_MS = 1000;
/** Slack on top of the speed limit, for rounding, ramps and frame hitches. */
const SPEED_MARGIN = 1.12;
const DISTANCE_SLACK = 4;
/** No honest sample is this far from the one before (10 per second, at most ~4 apart). */
const MAX_STEP = 15;
/** A car this close to a boost box's centre has touched it. */
const BOOST_REACH = 2.4;
/** Higher than this off the ground, the car is in the air (off a ramp). */
const AIRBORNE_Y = 0.9;
/** How fast the speed limit falls back after a boost or on reaching grass (the car's own rate is 5/s). */
const SLOWDOWN_RATE = 4;
/** Where the car may be at the start, plus how far it could have got since. */
const START_RADIUS = 8;

export interface RefereeEvent {
  kind: 'checkpoint' | 'lap';
  /** Milliseconds since the run started, on the server's clock. */
  atMs: number;
}

interface Sample {
  x: number;
  y: number;
  z: number;
  ct: number;
  /** Server time it arrived. */
  at: number;
  /** Distance travelled and distance allowed since the start of the run. */
  travelled: number;
  allowed: number;
}

export class Referee {
  /** Why the run cannot count, or null while it looks honest. */
  violation: string | null = null;
  readonly lapTimesMs: number[] = [];
  /** Time since the start at every gate passed; see RunResult.splitsMs. */
  readonly splitsMs: number[] = [];
  /** Index into geometry.gates of the next gate to pass. */
  nextGate = 0;

  private samples: Sample[] = [];
  private last: Sample | null = null;
  private lapStartedAt: number;
  private speedLimit = CAR_MAX_SPEED;
  private boostedUntilCt = -1;

  constructor(
    private readonly geometry: TrackGeometry,
    private readonly startedAt: number,
    private readonly minLapMs: number,
  ) {
    this.lapStartedAt = startedAt;
  }

  get checkpointsInLap(): number {
    return this.nextGate;
  }

  /** Checks one reported position. Returns the checkpoints and laps it completed. */
  addPose(x: number, y: number, z: number, ct: number, now: number): RefereeEvent[] {
    if (this.violation) return [];
    const { arena } = this.geometry;
    if (Math.abs(x) > arena.halfWidth + 3 || Math.abs(z) > arena.halfDepth + 3 || y < -2 || y > 25) {
      return this.flag('left the track area');
    }
    if (!Number.isFinite(ct) || ct < 0 || ct > now - this.startedAt + CLOCK_AHEAD_MS) {
      return this.flag('clock running ahead of real time');
    }

    const last = this.last;
    if (!last) {
      const reach = START_RADIUS + (CAR_MAX_SPEED * SPEED_MARGIN * ct) / 1000;
      if (Math.hypot(x - this.geometry.spawn[0], z - this.geometry.spawn[1]) > reach) {
        return this.flag('did not start on the grid');
      }
      this.last = { x, y, z, ct, at: now, travelled: 0, allowed: 0 };
      this.samples.push(this.last);
      return [];
    }
    if (ct < last.ct) return this.flag('clock running backwards');

    const from: Vec2 = [last.x, last.z];
    const to: Vec2 = [x, z];
    const step = Math.hypot(x - last.x, z - last.z);
    if (step > MAX_STEP) return this.flag('jumped across the track');

    for (const wall of this.geometry.walls) {
      if (Math.min(last.y, y) < wall.height + 0.3 && segmentsCross(from, to, wall.a, wall.b)) {
        return this.flag('drove through a wall');
      }
    }

    // The speed limit for this stretch: higher right after a boost, lower on grass, and
    // easing down (rather than dropping at once) the way the car itself slows.
    for (const boost of this.geometry.boosts) {
      if (segmentDistanceSq(boost, from, to) <= BOOST_REACH * BOOST_REACH) this.boostedUntilCt = ct + CAR_EFFECT_MS + 250;
    }
    const dt = (ct - last.ct) / 1000;
    const middle: Vec2 = [(last.x + x) / 2, (last.z + z) / 2];
    const airborne = Math.max(last.y, y) > AIRBORNE_Y;
    const onGrass = !airborne && !isOnRoad(this.geometry, middle) && !isOnRoad(this.geometry, to);
    let target = CAR_MAX_SPEED;
    if (ct <= this.boostedUntilCt) target *= CAR_BOOST_FACTOR;
    if (onGrass) target *= CAR_GRASS_FACTOR;
    this.speedLimit = this.speedLimit <= target ? target : target + (this.speedLimit - target) * Math.exp(-SLOWDOWN_RATE * dt);

    const sample: Sample = {
      x,
      y,
      z,
      ct,
      at: now,
      travelled: last.travelled + step,
      allowed: last.allowed + this.speedLimit * dt,
    };
    this.samples.push(sample);
    while (this.samples.length > 2 && this.samples[1]!.ct <= ct - WINDOW_MS) this.samples.shift();
    const oldest = this.samples[0]!;
    if (sample.travelled - oldest.travelled > (sample.allowed - oldest.allowed) * SPEED_MARGIN + DISTANCE_SLACK) {
      return this.flag('faster than the car can go');
    }

    this.last = sample;
    return this.crossGates(last, sample);
  }

  private crossGates(from: Sample, to: Sample): RefereeEvent[] {
    const events: RefereeEvent[] = [];
    const gates = this.geometry.gates;
    const gate = gates[this.nextGate];
    if (!gate) return events;
    const before = (from.x - gate.pos[0]) * gate.dir[0] + (from.z - gate.pos[1]) * gate.dir[1];
    const after = (to.x - gate.pos[0]) * gate.dir[0] + (to.z - gate.pos[1]) * gate.dir[1];
    if (before >= 0 || after < 0) return events;
    // Where and when the car crossed the gate's line, between the two samples.
    const f = before / (before - after);
    const crossX = from.x + (to.x - from.x) * f;
    const crossZ = from.z + (to.z - from.z) * f;
    const lateral = Math.abs((crossX - gate.pos[0]) * -gate.dir[1] + (crossZ - gate.pos[1]) * gate.dir[0]);
    if (lateral > gate.half) return events;

    const crossedAt = from.at + (to.at - from.at) * f;
    const atMs = Math.round(crossedAt - this.startedAt);
    this.splitsMs.push(atMs);
    if (this.nextGate < gates.length - 1) {
      this.nextGate += 1;
      events.push({ kind: 'checkpoint', atMs });
      return events;
    }
    const lapMs = Math.round(crossedAt - this.lapStartedAt);
    if (lapMs < this.minLapMs) {
      this.flag('lap faster than the track allows');
      return events;
    }
    this.lapTimesMs.push(lapMs);
    this.lapStartedAt = crossedAt;
    this.nextGate = 0;
    events.push({ kind: 'lap', atMs });
    return events;
  }

  private flag(reason: string): RefereeEvent[] {
    this.violation ??= reason;
    return [];
  }
}
