import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocket, WebSocketServer, type RawData } from 'ws';
import {
  MAX_POS_HZ,
  findTrack,
  RACE_LAPS,
  SNAPSHOT_HZ,
  type CarEffect,
  type CarPose,
  type ClientMessage,
  type PublicSession,
  type ServerMessage,
  type SnapshotCar,
} from '@bitrise-grand-prix/shared';
import { StoreError, type Player, type Session, type SessionStore } from './store.js';

/** player: drives a car. spectator: sees every car (the big screen). watcher: session updates only. */
type Role = 'player' | 'spectator' | 'watcher';

interface Client {
  ws: WebSocket;
  role: Role;
  code: string;
  playerId: string | null;
  pose: CarPose | null;
  fx: CarEffect;
  alive: boolean;
  posWindowStart: number;
  posCount: number;
}

const HEARTBEAT_MS = 15_000;
/** Coalesces bursts of session changes into at most this many broadcasts per second. */
const SESSION_BROADCAST_HZ = 4;
const MAX_MESSAGE_BYTES = 1024;
const MAX_WATCHERS_PER_SESSION = 200;
/** Leaderboard rows sent to the game; it shows the top few plus the player's own row. */
const GAME_LEADERBOARD_ROWS = 5;

/**
 * What the game needs of a session, which is much less than the controller site does. A busy
 * drop-in session collects hundreds of drivers and runs; phones only need the cars that are
 * on track now and the top of the board, so they are not sent the rest on every update.
 */
function gameView(full: PublicSession, playerId: string | null): PublicSession {
  const top = full.leaderboard.slice(0, GAME_LEADERBOARD_ROWS);
  const own = playerId ? full.leaderboard.find((entry) => entry.playerId === playerId) : undefined;
  return {
    ...full,
    players: full.players.filter((player) => player.connected || player.id === playerId),
    leaderboard: own && own.rank > GAME_LEADERBOARD_ROWS ? [...top, own] : top,
    results: [],
  };
}

const round = (value: number) => Math.round(value * 100) / 100;

function isPose(value: unknown): value is CarPose {
  return Array.isArray(value) && value.length === 4 && value.every((n) => typeof n === 'number' && Number.isFinite(n));
}

/**
 * The realtime side of a session. The server never simulates physics: each phone runs its
 * own car and reports its position, and this hub batches those into one snapshot per tick.
 */
export class RealtimeHub {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
  private readonly rooms = new Map<string, Set<Client>>();
  private readonly dirtySessions = new Set<string>();
  /** Rooms that still need one empty snapshot so ghosts of finished cars disappear. */
  private readonly hadCars = new Set<string>();
  private readonly timers: NodeJS.Timeout[] = [];

  /** `publicUrl`: the site's public address, accepted as a WebSocket origin besides the Host itself. */
  constructor(
    private readonly store: SessionStore,
    private readonly publicUrl: string | null = null,
  ) {
    store.on('change', (code: string) => this.dirtySessions.add(code));
    store.on('closed', (code: string) => this.broadcast(code, { t: 'closed' }));
    store.on('removed', (code: string, playerId: string) => {
      for (const client of this.rooms.get(code) ?? []) {
        if (client.playerId === playerId) {
          this.send(client, { t: 'removed' });
          client.ws.close(4003, 'removed');
        }
      }
    });

    this.timers.push(
      setInterval(() => this.sendSnapshots(), 1000 / SNAPSHOT_HZ),
      setInterval(() => this.flushSessionUpdates(), 1000 / SESSION_BROADCAST_HZ),
      setInterval(() => this.heartbeat(), HEARTBEAT_MS),
    );
  }

  attach(server: Server): void {
    server.on('upgrade', (request, socket, head) => this.handleUpgrade(request, socket, head));
  }

  close(): void {
    for (const timer of this.timers) clearInterval(timer);
    for (const room of this.rooms.values()) for (const client of room) client.ws.terminate();
    this.wss.close();
  }

  private handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    const url = new URL(request.url ?? '/', 'http://localhost');
    if (url.pathname !== '/ws') {
      socket.destroy();
      return;
    }

    const session = this.store.getSession(url.searchParams.get('session') ?? '');
    const roleParam = url.searchParams.get('role');
    const role: Role = roleParam === 'player' || roleParam === 'spectator' ? roleParam : 'watcher';
    const player = role === 'player' && session ? this.store.findPlayerByToken(session, url.searchParams.get('token') ?? '') : undefined;

    let refusal: string | null = null;
    if (!this.originAllowed(request)) refusal = '403 Forbidden';
    else if (!session) refusal = '404 Not Found';
    else if (role === 'player' && !player) refusal = '401 Unauthorized';
    else if (role !== 'player' && (this.rooms.get(session.code)?.size ?? 0) >= MAX_WATCHERS_PER_SESSION) refusal = '503 Service Unavailable';
    if (!session || refusal) {
      socket.write(`HTTP/1.1 ${refusal}\r\nConnection: close\r\n\r\n`);
      socket.destroy();
      return;
    }

    this.wss.handleUpgrade(request, socket, head, (ws) => this.onConnection(ws, session, role, player ?? null));
  }

  /**
   * Browsers always send an Origin; a page on another site must not open sockets here with a
   * player's token. Tools (the bots, curl) send none and are let through on their token alone.
   */
  private originAllowed(request: IncomingMessage): boolean {
    const origin = request.headers.origin;
    if (!origin) return true;
    try {
      const host = new URL(origin).host;
      return host === request.headers.host || (this.publicUrl !== null && host === new URL(this.publicUrl).host);
    } catch {
      return false;
    }
  }

  private onConnection(ws: WebSocket, session: Session, role: Role, player: Player | null): void {
    const client: Client = {
      ws,
      role,
      code: session.code,
      playerId: player?.id ?? null,
      pose: null,
      fx: 0,
      alive: true,
      posWindowStart: 0,
      posCount: 0,
    };

    let room = this.rooms.get(session.code);
    if (!room) {
      room = new Set();
      this.rooms.set(session.code, room);
    }
    // One live connection per player: a reload or a second tab replaces the old one.
    if (player) {
      for (const other of room) {
        if (other.playerId === player.id) other.ws.close(4001, 'replaced');
      }
    }
    room.add(client);
    if (player) this.store.setConnected(session, player, true);

    const full = this.store.toPublic(session);
    this.send(client, {
      t: 'welcome',
      you: player ? full.players.find((p) => p.id === player.id) ?? null : null,
      session: role === 'watcher' ? full : gameView(full, player?.id ?? null),
      laps: RACE_LAPS,
      // 0 (never expected) leaves the game with the limit from its own copy of the track file.
      timeLimitMs: findTrack(session.trackId)?.timeLimitMs ?? 0,
    });
    if (session.status === 'closed') this.send(client, { t: 'closed' });

    ws.on('pong', () => {
      client.alive = true;
    });
    ws.on('message', (data) => this.onMessage(client, data));
    ws.on('error', () => ws.terminate());
    ws.on('close', () => this.onClose(client));
  }

  private onClose(client: Client): void {
    const room = this.rooms.get(client.code);
    room?.delete(client);
    if (room?.size === 0) this.rooms.delete(client.code);

    if (!client.playerId) return;
    const session = this.store.getSession(client.code);
    const player = session?.players.get(client.playerId);
    if (!session || !player) return;
    // The player may already be back on a newer connection (see "replaced" above).
    const stillConnected = [...(room ?? [])].some((other) => other.playerId === client.playerId);
    if (!stillConnected) this.store.setConnected(session, player, false);
  }

  private onMessage(client: Client, data: RawData): void {
    let message: ClientMessage;
    try {
      message = JSON.parse(data.toString()) as ClientMessage;
    } catch {
      return;
    }
    if (!message || typeof message !== 'object') return;

    if (message.t === 'ping') {
      this.send(client, { t: 'pong', n: Number(message.n) || 0 });
      return;
    }

    if (client.role !== 'player' || !client.playerId) return;
    const session = this.store.getSession(client.code);
    const player = session?.players.get(client.playerId);
    if (!session || !player) return;

    try {
      switch (message.t) {
        case 'pos': {
          if (!isPose(message.p) || typeof message.ct !== 'number' || !this.allowPosition(client)) return;
          client.pose = [round(message.p[0]), round(message.p[1]), round(message.p[2]), round(message.p[3])];
          client.fx = message.fx === 1 || message.fx === 2 ? message.fx : 0;
          // The referee, not the phone, decides when checkpoints and laps happen.
          if (this.store.recordPose(session, player, message.p, message.ct).length > 0) this.sendStanding(client, session, player);
          return;
        }
        case 'run_start': {
          const at = this.store.startRun(session, player);
          this.send(client, { t: 'run_started', at });
          this.sendStanding(client, session, player);
          return;
        }
        case 'run_finish': {
          const outcome = this.store.finishRun(session, player, { finished: message.finished === true });
          client.pose = null;
          this.send(client, { t: 'run_result', ...outcome });
          return;
        }
        default:
          return;
      }
    } catch (error) {
      const text = error instanceof StoreError ? error.message : 'Something went wrong.';
      if (!(error instanceof StoreError)) console.error(error);
      this.send(client, { t: 'error', message: text });
    }
  }

  /** The live projected position, sent to the driver at the start and at every gate. */
  private sendStanding(client: Client, session: Session, player: Player): void {
    const standing = this.store.standing(session, player);
    if (standing) this.send(client, { t: 'standing', ...standing });
  }

  private allowPosition(client: Client): boolean {
    const now = Date.now();
    if (now - client.posWindowStart >= 1000) {
      client.posWindowStart = now;
      client.posCount = 0;
    }
    client.posCount += 1;
    return client.posCount <= MAX_POS_HZ;
  }

  private sendSnapshots(): void {
    for (const [code, room] of this.rooms) {
      const session = this.store.getSession(code);
      if (!session) continue;

      const cars: SnapshotCar[] = [];
      for (const client of room) {
        if (!client.playerId || !client.pose) continue;
        const player = session.players.get(client.playerId);
        if (!player?.run) continue;
        cars.push({ id: player.id, p: client.pose, lap: this.store.lapsCompleted(player) + 1, fx: client.fx });
      }

      if (cars.length === 0) {
        if (!this.hadCars.delete(code)) continue;
      } else {
        this.hadCars.add(code);
      }

      const payload = JSON.stringify({ t: 'snapshot', cars } satisfies ServerMessage);
      for (const client of room) {
        if (client.role !== 'watcher' && client.ws.readyState === WebSocket.OPEN) client.ws.send(payload);
      }
    }
  }

  private flushSessionUpdates(): void {
    if (this.dirtySessions.size === 0) return;
    const codes = [...this.dirtySessions];
    this.dirtySessions.clear();
    for (const code of codes) {
      const session = this.store.getSession(code);
      const room = this.rooms.get(code);
      if (!session || !room) continue;

      const full = this.store.toPublic(session);
      const forWatchers = JSON.stringify({ t: 'session', session: full } satisfies ServerMessage);
      // Everyone in the game gets the same trimmed view, except a player ranked below the
      // rows it contains, who also gets their own row.
      const forGame = JSON.stringify({ t: 'session', session: gameView(full, null) } satisfies ServerMessage);
      const ranks = new Map(full.leaderboard.map((entry) => [entry.playerId, entry.rank]));

      for (const client of room) {
        if (client.ws.readyState !== WebSocket.OPEN) continue;
        if (client.role === 'watcher') {
          client.ws.send(forWatchers);
        } else if (client.playerId && (ranks.get(client.playerId) ?? 0) > GAME_LEADERBOARD_ROWS) {
          client.ws.send(JSON.stringify({ t: 'session', session: gameView(full, client.playerId) } satisfies ServerMessage));
        } else {
          client.ws.send(forGame);
        }
      }
    }
  }

  private heartbeat(): void {
    for (const room of this.rooms.values()) {
      for (const client of room) {
        if (!client.alive) {
          client.ws.terminate();
          continue;
        }
        client.alive = false;
        client.ws.ping();
      }
    }
  }

  private broadcast(code: string, message: ServerMessage): void {
    const room = this.rooms.get(code);
    if (!room) return;
    const payload = JSON.stringify(message);
    for (const client of room) {
      if (client.ws.readyState === WebSocket.OPEN) client.ws.send(payload);
    }
  }

  private send(client: Client, message: ServerMessage): void {
    if (client.ws.readyState === WebSocket.OPEN) client.ws.send(JSON.stringify(message));
  }
}
