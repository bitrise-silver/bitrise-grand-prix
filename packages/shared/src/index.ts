// Types and constants shared by the session server and the controller site.
// The Godot game speaks the same JSON protocol; see game/scripts/net.gd.

export * from './tracks.js';
export * from './geometry.js';

/** A run is over when the player completes this many laps... */
export const RACE_LAPS = 3;
/** ...or when this much time has passed since GO. */
export const RUN_TIME_LIMIT_MS = 90_000;
/** How often the server fans out car positions to everyone in a session. */
export const SNAPSHOT_HZ = 10;
/** Upper bound on position messages accepted per client per second. */
export const MAX_POS_HZ = 20;
export const MAX_NAME_LENGTH = 16;
export const MAX_SESSION_NAME_LENGTH = 40;
/** Concurrent players per session. Ghost rendering on phones is the real limit, not the server. */
export const MAX_PLAYERS_PER_SESSION = 40;

/** How long a join code from the QR screen works after it appears. */
export const JOIN_CODE_TTL_MS = 10_000;
/**
 * How often the QR screen shows a new join code. Shorter than JOIN_CODE_TTL_MS on purpose:
 * a phone that scans a code just before it changes still has five seconds to open the link.
 */
export const JOIN_CODE_ROTATE_MS = 5_000;
/** How long a phone that scanned a valid code has to pick a driver name. */
export const JOIN_TICKET_TTL_MS = 3 * 60_000;

// The car's limits, which the server's referee holds every run to. They must match
// game/scripts/car.gd.
export const CAR_MAX_SPEED = 26;
export const CAR_BOOST_FACTOR = 1.5;
export const CAR_GRASS_FACTOR = 0.38;
export const CAR_EFFECT_MS = 1000;

export type SessionStatus = 'open' | 'closed';
export type PlayerState = 'lobby' | 'racing' | 'finished';

export interface PublicPlayer {
  id: string;
  name: string;
  /** Hex colour of the player's car, e.g. "#9247c2". */
  color: string;
  connected: boolean;
  state: PlayerState;
  attempts: number;
}

export interface RunResult {
  playerId: string;
  name: string;
  color: string;
  /** True when all laps were completed inside the time limit. */
  finished: boolean;
  lapsCompleted: number;
  /** Checkpoints passed in the unfinished lap; only used to rank runs that timed out. */
  checkpointsInLap: number;
  /** Total run time. For a run that timed out this is the time limit. */
  totalMs: number;
  lapTimesMs: number[];
  bestLapMs: number | null;
  /**
   * Time since GO at every gate passed, checkpoints and lap lines alike, in driving order.
   * Lets a later run see where it stands mid-lap. Missing on runs recorded before it existed.
   */
  splitsMs?: number[];
  /** Epoch milliseconds. */
  finishedAt: number;
}

export interface LeaderboardEntry extends RunResult {
  rank: number;
}

export interface PublicSession {
  code: string;
  name: string;
  trackId: string;
  status: SessionStatus;
  createdAt: number;
  closedAt: number | null;
  /** Players with a live connection right now. */
  activePlayers: number;
  players: PublicPlayer[];
  /** Best run per player, best first. */
  leaderboard: LeaderboardEntry[];
  /** The most recent recorded runs, newest first (capped; see `runs` for the total). */
  results: RunResult[];
  /** How many runs have been recorded in total. */
  runs: number;
}

export interface SessionSummary {
  code: string;
  name: string;
  trackId: string;
  status: SessionStatus;
  createdAt: number;
  activePlayers: number;
  totalPlayers: number;
  runs: number;
}

export interface ServerConfig {
  /** True when creating and closing sessions needs the admin token. */
  authRequired: boolean;
  /** Explicit base URL that phones should open (PUBLIC_URL), or null when not configured. */
  publicUrl: string | null;
  /** The server's LAN address, used for the QR code when the host opened the site on localhost. */
  lanIp: string | null;
  raceLaps: number;
  runTimeLimitMs: number;
  /** False until the Godot web export has been built into the server's game directory. */
  gameAvailable: boolean;
}

/** A join code for the QR screen. Only the host can ask for one. */
export interface JoinCodeResponse {
  token: string;
  /** When the QR screen shows the next code. Epoch milliseconds on the server's clock. */
  rotatesAt: number;
  /** When this code stops working. */
  expiresAt: number;
  /** The server's clock when it answered, so the screen can time the next code. */
  serverNow: number;
}

/**
 * A link for the device that shows the QR code (a phone at the booth, say). The key in it can
 * fetch join codes for one session and do nothing else; creating a new one cancels the old.
 */
export interface ScreenKeyResponse {
  key: string;
}

/** What a phone gets for a valid join code: one go at joining, within a few minutes. */
export interface JoinTicketResponse {
  ticket: string;
  expiresAt: number;
}

export interface JoinResponse {
  playerId: string;
  /** Secret that authenticates this player's WebSocket. Keep it on the device. */
  token: string;
  name: string;
  color: string;
}

// ---------------------------------------------------------------------------------------------
// WebSocket protocol: /ws?session=CODE&role=player&token=...   or   role=spectator
// Every message is a JSON object with a `t` discriminator.
// ---------------------------------------------------------------------------------------------

/** Position of one car: x, y, z, heading in radians. */
export type CarPose = [x: number, y: number, z: number, heading: number];

/**
 * Players only report where their car is. The server works out checkpoints, laps and times
 * itself from those positions and its own clock, and checks that the car could really have
 * moved that way (see packages/server/src/referee.ts).
 */
export type ClientMessage =
  | { t: 'run_start' }
  /** `ct`: milliseconds since GO on the phone's clock. */
  | { t: 'pos'; p: CarPose; ct: number; fx?: CarEffect }
  /** `finished`: the phone saw all laps done (rather than the time running out). */
  | { t: 'run_finish'; finished: boolean }
  | { t: 'ping'; n: number };

/** Visual effect currently on a car: 0 none, 1 boosted, 2 slowed. */
export type CarEffect = 0 | 1 | 2;

export interface SnapshotCar {
  id: string;
  p: CarPose;
  lap: number;
  fx: CarEffect;
}

export interface StandingRow {
  rank: number;
  name: string;
  color: string;
  you: boolean;
}

/**
 * Where a run in progress stands: at the last gate the driver passed, compared with every
 * other driver's best run at that same gate. `rank` is 0 until the first gate.
 */
export interface Standing {
  rank: number;
  of: number;
  /** How far behind the driver one place ahead was, or null when leading or before the first gate. */
  gapAheadMs: number | null;
  /** How far ahead of the driver one place behind, or null when last or before the first gate. */
  gapBehindMs: number | null;
  /** The top few in projected order, plus the driver's own row when it is further down. */
  rows: StandingRow[];
}

export type ServerMessage =
  | { t: 'welcome'; you: PublicPlayer | null; session: PublicSession; laps: number; timeLimitMs: number }
  | ({ t: 'standing' } & Standing)
  | { t: 'session'; session: PublicSession }
  | { t: 'snapshot'; cars: SnapshotCar[] }
  | { t: 'run_started'; at: number }
  | { t: 'run_result'; accepted: boolean; reason?: string; result?: RunResult; rank?: number }
  | { t: 'closed' }
  | { t: 'removed' }
  | { t: 'pong'; n: number }
  | { t: 'error'; message: string };

export const CAR_COLORS = [
  '#9247c2',
  '#11bba9',
  '#f7596c',
  '#fd9730',
  '#f9cc15',
  '#4f9bde',
  '#4eb76c',
  '#ae63de',
  '#ed720c',
  '#55cec3',
  '#ff8091',
  '#71b8ef',
] as const;

/** Orders two runs: completed runs by time, then timed-out runs by how far they got. */
export function compareRuns(a: RunResult, b: RunResult): number {
  if (a.finished !== b.finished) return a.finished ? -1 : 1;
  if (a.finished) return a.totalMs - b.totalMs || a.finishedAt - b.finishedAt;
  return (
    b.lapsCompleted - a.lapsCompleted ||
    b.checkpointsInLap - a.checkpointsInLap ||
    a.finishedAt - b.finishedAt
  );
}

/** Best run per player, ranked. */
export function buildLeaderboard(results: RunResult[]): LeaderboardEntry[] {
  const best = new Map<string, RunResult>();
  for (const result of results) {
    const current = best.get(result.playerId);
    if (!current || compareRuns(result, current) < 0) best.set(result.playerId, result);
  }
  return [...best.values()].sort(compareRuns).map((result, index) => ({ ...result, rank: index + 1 }));
}

/**
 * Time since GO at which `run` passed gate `gate` (0-based over the whole run), or null when
 * it never got there. Runs recorded before splits existed are assumed to have kept an even pace.
 */
export function splitAt(run: RunResult, gate: number, gatesPerLap: number): number | null {
  if (run.splitsMs) return run.splitsMs[gate] ?? null;
  const reached = run.finished ? RACE_LAPS * gatesPerLap : run.lapsCompleted * gatesPerLap + run.checkpointsInLap;
  if (gate >= reached) return null;
  const total = run.finished ? run.totalMs : RUN_TIME_LIMIT_MS;
  return Math.round((total * (gate + 1)) / reached);
}

/**
 * Projected position of a run in progress. `others` is every other driver's best run, in
 * leaderboard order; `splitsMs` is the run so far (see RunResult.splitsMs).
 */
export function projectStanding(
  others: RunResult[],
  you: { name: string; color: string },
  splitsMs: number[],
  gatesPerLap: number,
  maxRows = 4,
): Standing {
  const of = others.length + 1;
  const gate = splitsMs.length - 1;
  const row = (run: { name: string; color: string }, isYou: boolean) => ({ name: run.name, color: run.color, you: isYou });

  if (gate < 0) {
    const order = [...others.slice(0, maxRows - 1).map((run) => row(run, false)), row(you, true)];
    return {
      rank: 0,
      of,
      gapAheadMs: null,
      gapBehindMs: null,
      rows: order.map((entry, index) => ({ ...entry, rank: entry.you ? 0 : index + 1 })),
    };
  }

  const yours = splitsMs[gate] ?? 0;
  const timed = others.map((run) => ({ run, split: splitAt(run, gate, gatesPerLap) }));
  // Equal times go to whoever set them first, which is never the run still in progress.
  const ahead = timed.filter((entry) => entry.split !== null && entry.split <= yours).sort((a, b) => a.split! - b.split!);
  const behind = timed.filter((entry) => entry.split === null || entry.split > yours);
  behind.sort((a, b) => {
    if (a.split === null || b.split === null) return a.split === null ? (b.split === null ? 0 : 1) : -1;
    return a.split - b.split;
  });

  const order = [...ahead.map((entry) => row(entry.run, false)), row(you, true), ...behind.map((entry) => row(entry.run, false))];
  const ranked = order.map((entry, index) => ({ ...entry, rank: index + 1 }));
  const rank = ahead.length + 1;
  const own = ranked[rank - 1];
  const rows = rank <= maxRows || !own ? ranked.slice(0, maxRows) : [...ranked.slice(0, maxRows - 1), own];
  const nextBehind = behind[0]?.split ?? null;
  return {
    rank,
    of,
    gapAheadMs: ahead.length > 0 ? yours - ahead[ahead.length - 1]!.split! : null,
    gapBehindMs: nextBehind === null ? null : nextBehind - yours,
    rows,
  };
}

export function formatRaceTime(ms: number): string {
  const totalCentis = Math.round(ms / 10);
  const minutes = Math.floor(totalCentis / 6000);
  const seconds = Math.floor((totalCentis % 6000) / 100);
  const centis = totalCentis % 100;
  return `${minutes}:${String(seconds).padStart(2, '0')}.${String(centis).padStart(2, '0')}`;
}
