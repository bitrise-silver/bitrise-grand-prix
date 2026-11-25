import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import {
  buildLeaderboard,
  CAR_COLORS,
  DEFAULT_TRACK_ID,
  findTrack,
  findTrackFile,
  MAX_NAME_LENGTH,
  MAX_PLAYERS_PER_SESSION,
  MAX_SESSION_NAME_LENGTH,
  projectStanding,
  RACE_LAPS,
  trackGeometry,
  type CarPose,
  type PlayerState,
  type PublicPlayer,
  type PublicSession,
  type RunResult,
  type SessionStatus,
  type SessionSummary,
  type Standing,
  type TrackGeometry,
  type TrackInfo,
} from '@bitrise-grand-prix/shared';
import { Referee, type RefereeEvent } from './referee.js';

/** Extra time after the limit before the server ends an abandoned run itself. */
const RUN_GRACE_MS = 5000;
const MAX_SESSIONS = 200;
const MAX_PLAYERS_TOTAL = 5000;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 5;

interface ActiveRun {
  startedAt: number;
  /** Decides checkpoints, laps and times from the reported positions, and spots cheating. */
  referee: Referee;
  timeout: NodeJS.Timeout | null;
}

export interface Player {
  id: string;
  /** SHA-256 of the player's secret token. The token itself is only ever handed to the player. */
  tokenHash: string;
  name: string;
  color: string;
  connected: boolean;
  state: PlayerState;
  attempts: number;
  run: ActiveRun | null;
}

export interface Session {
  code: string;
  name: string;
  trackId: string;
  status: SessionStatus;
  createdAt: number;
  closedAt: number | null;
  players: Map<string, Player>;
  results: RunResult[];
  /** SHA-256 of the key that lets one device (the booth's QR phone) fetch join codes. */
  screenKeyHash?: string | null;
}

export class StoreError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export interface RunOutcome {
  accepted: boolean;
  reason?: string;
  result?: RunResult;
  rank?: number;
}

interface PersistedSession extends Omit<Session, 'players'> {
  /** Files written before tokens were hashed have `token` instead of `tokenHash`. */
  players: (Omit<Player, 'run' | 'connected' | 'state' | 'tokenHash'> & { tokenHash?: string; token?: string })[];
}

export interface StoreOptions {
  /** JSON file to persist sessions to; null keeps everything in memory. */
  persistPath?: string | null;
  now?: () => number;
}

const hashToken = (token: string) => createHash('sha256').update(token).digest('hex');

export function sanitizeName(raw: unknown, maxLength = MAX_NAME_LENGTH): string {
  if (typeof raw !== 'string') return '';
  const cleaned = raw
    // Control characters, and angle brackets so a name can never be read as markup downstream.
    .replace(/[\u0000-\u001f\u007f<>]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return [...cleaned].slice(0, maxLength).join('').trim();
}

/**
 * Sessions, players and results. Emits `change` with a session code whenever something a
 * client can see has changed, and `closed` / `removed` for the two events that end a connection.
 */
export class SessionStore extends EventEmitter {
  private readonly sessions = new Map<string, Session>();
  private readonly persistPath: string | null;
  private readonly now: () => number;
  private saveTimer: NodeJS.Timeout | null = null;
  private readonly geometries = new Map<string, TrackGeometry>();

  constructor(options: StoreOptions = {}) {
    super();
    this.persistPath = options.persistPath ?? null;
    this.now = options.now ?? Date.now;
    this.load();
  }

  // --- sessions ------------------------------------------------------------------------------

  createSession(input: { name?: unknown; trackId?: unknown }): Session {
    if (this.sessions.size >= MAX_SESSIONS) {
      throw new StoreError(409, 'Too many sessions. Delete an old one first.');
    }
    const trackId = typeof input.trackId === 'string' && input.trackId ? input.trackId : DEFAULT_TRACK_ID;
    if (!findTrack(trackId)) throw new StoreError(400, `Unknown track "${trackId}".`);

    const session: Session = {
      code: this.newCode(),
      name: sanitizeName(input.name, MAX_SESSION_NAME_LENGTH) || 'Race session',
      trackId,
      status: 'open',
      createdAt: this.now(),
      closedAt: null,
      players: new Map(),
      results: [],
    };
    this.sessions.set(session.code, session);
    this.touch(session);
    return session;
  }

  getSession(code: string): Session | undefined {
    return this.sessions.get(code.toUpperCase());
  }

  requireSession(code: string): Session {
    const session = this.getSession(code);
    if (!session) throw new StoreError(404, 'Session not found.');
    return session;
  }

  listSessions(): Session[] {
    return [...this.sessions.values()].sort((a, b) => b.createdAt - a.createdAt);
  }

  closeSession(code: string): Session {
    const session = this.requireSession(code);
    if (session.status === 'closed') return session;
    session.status = 'closed';
    session.closedAt = this.now();
    for (const player of session.players.values()) this.clearRun(player);
    this.emit('closed', session.code);
    this.touch(session);
    return session;
  }

  reopenSession(code: string): Session {
    const session = this.requireSession(code);
    session.status = 'open';
    session.closedAt = null;
    this.touch(session);
    return session;
  }

  deleteSession(code: string): void {
    const session = this.requireSession(code);
    for (const player of session.players.values()) this.clearRun(player);
    this.emit('closed', session.code);
    this.sessions.delete(session.code);
    this.scheduleSave();
  }

  // --- players -------------------------------------------------------------------------------

  /** Adds a player. Returns the player and their secret token, which is not stored. */
  addPlayer(code: string, rawName: unknown): { player: Player; token: string } {
    const session = this.requireSession(code);
    if (session.status !== 'open') throw new StoreError(409, 'This session is closed.');
    if (session.players.size >= MAX_PLAYERS_TOTAL) throw new StoreError(409, 'This session is full.');
    if (this.activePlayers(session) >= MAX_PLAYERS_PER_SESSION) {
      throw new StoreError(409, 'The track is full right now. Try again in a minute.');
    }

    const base = sanitizeName(rawName) || `Racer ${session.players.size + 1}`;
    const taken = new Set([...session.players.values()].map((player) => player.name.toLowerCase()));
    let name = base;
    for (let suffix = 2; taken.has(name.toLowerCase()); suffix += 1) {
      const tail = ` ${suffix}`;
      name = [...base].slice(0, MAX_NAME_LENGTH - tail.length).join('') + tail;
    }

    const token = randomBytes(24).toString('base64url');
    const player: Player = {
      id: randomBytes(5).toString('hex'),
      tokenHash: hashToken(token),
      name,
      color: CAR_COLORS[session.players.size % CAR_COLORS.length] ?? CAR_COLORS[0],
      connected: false,
      state: 'lobby',
      attempts: 0,
      run: null,
    };
    session.players.set(player.id, player);
    this.touch(session);
    return { player, token };
  }

  /** A new key for the device that shows the QR code. The old one stops working. */
  createScreenKey(code: string): string {
    const session = this.requireSession(code);
    const key = randomBytes(24).toString('base64url');
    session.screenKeyHash = hashToken(key);
    this.touch(session);
    return key;
  }

  checkScreenKey(session: Session, key: unknown): boolean {
    if (typeof key !== 'string' || !key || key.length > 128 || !session.screenKeyHash) return false;
    const stored = Buffer.from(session.screenKeyHash);
    const given = Buffer.from(hashToken(key));
    return stored.length === given.length && timingSafeEqual(stored, given);
  }

  findPlayerByToken(session: Session, token: string): Player | undefined {
    if (!token || token.length > 128) return undefined;
    const given = Buffer.from(hashToken(token));
    for (const player of session.players.values()) {
      const stored = Buffer.from(player.tokenHash);
      if (stored.length === given.length && timingSafeEqual(stored, given)) return player;
    }
    return undefined;
  }

  /** Removes a player and their results, e.g. when a name on the big screen is not acceptable. */
  removePlayer(code: string, playerId: string): void {
    const session = this.requireSession(code);
    const player = session.players.get(playerId);
    if (!player) throw new StoreError(404, 'Player not found.');
    this.clearRun(player);
    session.players.delete(playerId);
    session.results = session.results.filter((result) => result.playerId !== playerId);
    this.emit('removed', session.code, playerId);
    this.touch(session);
  }

  setConnected(session: Session, player: Player, connected: boolean): void {
    if (player.connected === connected) return;
    player.connected = connected;
    if (!connected) {
      // A dropped connection abandons the run; nothing is recorded for it.
      this.clearRun(player);
      if (player.state === 'racing') player.state = 'lobby';
    }
    this.touch(session, false);
  }

  activePlayers(session: Session): number {
    let count = 0;
    for (const player of session.players.values()) if (player.connected) count += 1;
    return count;
  }

  // --- runs ----------------------------------------------------------------------------------

  startRun(session: Session, player: Player): number {
    if (session.status !== 'open') throw new StoreError(409, 'This session is closed.');
    this.clearRun(player);
    const startedAt = this.now();
    const run: ActiveRun = {
      startedAt,
      referee: new Referee(this.geometry(session), startedAt, this.track(session).minLapMs),
      timeout: null,
    };
    run.timeout = setTimeout(() => {
      if (player.run === run) this.finishRun(session, player, { finished: false });
    }, this.track(session).timeLimitMs + RUN_GRACE_MS);
    run.timeout.unref?.();
    player.run = run;
    player.state = 'racing';
    player.attempts += 1;
    this.touch(session, false);
    return startedAt;
  }

  /**
   * Hands a reported position to the run's referee. `ct` is the phone's time since GO.
   * Returns the checkpoints and laps it completed.
   */
  recordPose(session: Session, player: Player, pose: CarPose, ct: number): RefereeEvent[] {
    const run = player.run;
    if (!run || run.referee.lapTimesMs.length >= RACE_LAPS) return [];
    return run.referee.addPose(pose[0], pose[1], pose[2], ct, this.now());
  }

  /**
   * Ends the player's run. Laps and times are the referee's, measured on the server's clock;
   * the phone only says whether it saw the run end at the finish line or on the clock.
   */
  finishRun(session: Session, player: Player, claim: { finished: boolean }): RunOutcome {
    const run = player.run;
    if (!run) return { accepted: false, reason: 'no active run' };
    const now = this.now();
    this.clearRun(player);
    player.state = 'finished';

    const referee = run.referee;
    const lapTimesMs = referee.lapTimesMs.slice(0, RACE_LAPS);
    const lapsCompleted = lapTimesMs.length;
    const completed = lapsCompleted >= RACE_LAPS;
    const limitMs = this.track(session).timeLimitMs;
    const totalMs = completed ? lapTimesMs.reduce((sum, ms) => sum + ms, 0) : limitMs;

    let reason = referee.violation;
    if (!reason && claim.finished && !completed) reason = 'the server did not see every lap';
    if (!reason && completed && totalMs > limitMs) reason = 'over the time limit';
    if (reason) {
      this.touch(session, false);
      return { accepted: false, reason };
    }
    // A run that never got anywhere is not worth a row on the board.
    if (!completed && lapsCompleted === 0 && referee.checkpointsInLap === 0) {
      this.touch(session, false);
      return { accepted: false, reason: 'no progress' };
    }

    const result: RunResult = {
      playerId: player.id,
      name: player.name,
      color: player.color,
      finished: completed,
      lapsCompleted,
      checkpointsInLap: completed ? 0 : referee.checkpointsInLap,
      totalMs,
      lapTimesMs,
      bestLapMs: lapsCompleted > 0 ? Math.min(...lapTimesMs) : null,
      splitsMs: referee.splitsMs.slice(0, RACE_LAPS * (this.track(session).checkpoints + 1)),
      finishedAt: now,
    };
    session.results.unshift(result);
    this.touch(session);
    const rank = buildLeaderboard(session.results).find((entry) => entry.playerId === player.id)?.rank;
    return { accepted: true, result, rank };
  }

  /** Laps the player's run in progress has completed, for the big screen. */
  lapsCompleted(player: Player): number {
    return player.run?.referee.lapTimesMs.length ?? 0;
  }

  /** Where the player's run in progress stands against everyone else's best; null without a run. */
  standing(session: Session, player: Player): Standing | null {
    if (!player.run) return null;
    const others = buildLeaderboard(session.results).filter((entry) => entry.playerId !== player.id);
    return projectStanding(others, player, player.run.referee.splitsMs, this.track(session).checkpoints + 1);
  }

  // --- views ---------------------------------------------------------------------------------

  toPublic(session: Session): PublicSession {
    return {
      code: session.code,
      name: session.name,
      trackId: session.trackId,
      status: session.status,
      createdAt: session.createdAt,
      closedAt: session.closedAt,
      activePlayers: this.activePlayers(session),
      players: [...session.players.values()].map(toPublicPlayer),
      leaderboard: buildLeaderboard(session.results),
      results: session.results.slice(0, 100),
      runs: session.results.length,
    };
  }

  toSummary(session: Session): SessionSummary {
    return {
      code: session.code,
      name: session.name,
      trackId: session.trackId,
      status: session.status,
      createdAt: session.createdAt,
      activePlayers: this.activePlayers(session),
      totalPlayers: session.players.size,
      runs: session.results.length,
    };
  }

  /** Writes pending changes now. Call before the process exits. */
  flush(): void {
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = null;
    this.save();
  }

  // --- internals -----------------------------------------------------------------------------

  private track(session: Session): TrackInfo {
    const track = findTrack(session.trackId);
    if (!track) throw new StoreError(500, `Track "${session.trackId}" is not available.`);
    return track;
  }

  private geometry(session: Session): TrackGeometry {
    let geometry = this.geometries.get(session.trackId);
    if (!geometry) {
      const file = findTrackFile(session.trackId);
      if (!file) throw new StoreError(500, `Track "${session.trackId}" is not available.`);
      geometry = trackGeometry(file);
      this.geometries.set(session.trackId, geometry);
    }
    return geometry;
  }

  private clearRun(player: Player): void {
    if (player.run?.timeout) clearTimeout(player.run.timeout);
    player.run = null;
  }

  private newCode(): string {
    for (;;) {
      let code = '';
      for (let i = 0; i < CODE_LENGTH; i += 1) code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
      if (!this.sessions.has(code)) return code;
    }
  }

  private touch(session: Session, persist = true): void {
    this.emit('change', session.code);
    if (persist) this.scheduleSave();
  }

  private scheduleSave(): void {
    if (!this.persistPath || this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null;
      this.save();
    }, 500);
    this.saveTimer.unref?.();
  }

  private save(): void {
    if (!this.persistPath) return;
    const data: PersistedSession[] = [...this.sessions.values()].map((session) => ({
      ...session,
      players: [...session.players.values()].map(({ id, tokenHash, name, color, attempts }) => ({
        id,
        tokenHash,
        name,
        color,
        attempts,
      })),
    }));
    try {
      mkdirSync(dirname(this.persistPath), { recursive: true });
      const tmp = `${this.persistPath}.tmp`;
      writeFileSync(tmp, JSON.stringify({ version: 1, sessions: data }));
      renameSync(tmp, this.persistPath);
    } catch (error) {
      console.error('Could not save sessions:', error);
    }
  }

  private load(): void {
    if (!this.persistPath || !existsSync(this.persistPath)) return;
    try {
      const parsed = JSON.parse(readFileSync(this.persistPath, 'utf8')) as { sessions?: PersistedSession[] };
      for (const stored of parsed.sessions ?? []) {
        const players = new Map<string, Player>();
        for (const { token, tokenHash, ...player } of stored.players) {
          const hash = tokenHash ?? (token ? hashToken(token) : '');
          if (!hash) continue;
          players.set(player.id, { ...player, tokenHash: hash, connected: false, state: 'lobby', run: null });
        }
        this.sessions.set(stored.code, { ...stored, players });
      }
    } catch (error) {
      console.error(`Could not read ${this.persistPath}; starting with no sessions.`, error);
    }
  }
}

function toPublicPlayer(player: Player): PublicPlayer {
  return {
    id: player.id,
    name: player.name,
    color: player.color,
    connected: player.connected,
    state: player.state,
    attempts: player.attempts,
  };
}
