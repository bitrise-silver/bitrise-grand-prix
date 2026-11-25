import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join as joinPath } from 'node:path';
import { describe, expect, it } from 'vitest';
import { projectStanding, RACE_LAPS, type RunResult } from '@bitrise-grand-prix/shared';
import { sanitizeName, SessionStore, StoreError } from '../src/store.js';
import { along, driveRun, gatesPerLap, geometry, join, lapLength, setup, startRun, toLine, track } from './drive.js';

describe('sanitizeName', () => {
  it('trims, collapses whitespace and limits the length', () => {
    expect(sanitizeName('  Ada   Lovelace  ')).toBe('Ada Lovelace');
    expect(sanitizeName('x'.repeat(40))).toHaveLength(16);
  });

  it('drops markup and control characters', () => {
    expect(sanitizeName('<b>Bob</b>\u0007')).toBe('bBob/b');
    expect(sanitizeName(42)).toBe('');
  });
});

describe('sessions and players', () => {
  it('creates a session with a code and the requested track', () => {
    const { session } = setup();
    expect(session.code).toMatch(/^[A-Z2-9]{5}$/);
    expect(session.status).toBe('open');
  });

  it('rejects an unknown track', () => {
    const { store } = setup();
    expect(() => store.createSession({ trackId: 'nope' })).toThrow(StoreError);
  });

  it('finds sessions case-insensitively', () => {
    const { store, session } = setup();
    expect(store.getSession(session.code.toLowerCase())).toBe(session);
  });

  it('gives duplicate names a suffix and falls back when the name is empty', () => {
    const ctx = setup();
    expect(join(ctx, 'Sam').name).toBe('Sam');
    expect(join(ctx, 'sam').name).toBe('sam 2');
    expect(join(ctx, '   ').name).toBe('Racer 3');
  });

  it('does not let anyone join a closed session', () => {
    const ctx = setup();
    ctx.store.closeSession(ctx.session.code);
    expect(() => join(ctx, 'Late')).toThrow('closed');
  });

  it('counts only connected players as active', () => {
    const ctx = setup();
    const a = join(ctx, 'A');
    join(ctx, 'B');
    ctx.store.setConnected(ctx.session, a, true);
    expect(ctx.store.toPublic(ctx.session).activePlayers).toBe(1);
    expect(ctx.store.toSummary(ctx.session).totalPlayers).toBe(2);
  });
});

describe('player tokens', () => {
  it('finds a player by their token, and by nothing else', () => {
    const ctx = setup();
    const { player, token } = ctx.store.addPlayer(ctx.session.code, 'A');
    expect(ctx.store.findPlayerByToken(ctx.session, token)).toBe(player);
    expect(ctx.store.findPlayerByToken(ctx.session, player.tokenHash)).toBeUndefined();
    expect(ctx.store.findPlayerByToken(ctx.session, '')).toBeUndefined();
  });

  it('never exposes tokens in the public view', () => {
    const ctx = setup();
    const { player, token } = ctx.store.addPlayer(ctx.session.code, 'A');
    const view = JSON.stringify(ctx.store.toPublic(ctx.session));
    expect(view).not.toContain(token);
    expect(view).not.toContain(player.tokenHash);
  });

  it('stores only a hash of the token on disk, and upgrades old files', () => {
    const file = joinPath(mkdtempSync(joinPath(tmpdir(), 'grand-prix-')), 'sessions.json');
    const ctx = setup({ persistPath: file });
    const { token } = ctx.store.addPlayer(ctx.session.code, 'A');
    ctx.store.flush();
    expect(readFileSync(file, 'utf8')).not.toContain(token);
    expect(new SessionStore({ persistPath: file }).findPlayerByToken(ctx.store.getSession(ctx.session.code)!, token)).toBeDefined();

    // A file from before hashing: the plain token still works once loaded, and is not written back.
    const old = JSON.parse(readFileSync(file, 'utf8')) as { sessions: { players: Record<string, unknown>[] }[] };
    const stored = old.sessions[0]!.players[0]!;
    delete stored.tokenHash;
    stored.token = 'legacy-token';
    writeFileSync(file, JSON.stringify(old));
    const reloaded = new SessionStore({ persistPath: file });
    const session = reloaded.getSession(ctx.session.code)!;
    expect(reloaded.findPlayerByToken(session, 'legacy-token')).toBeDefined();
    reloaded.flush();
    expect(readFileSync(file, 'utf8')).not.toContain('legacy-token');
  });
});

describe('runs, refereed by the server', () => {
  it('accepts an honest run and times it on the server clock', () => {
    const ctx = setup();
    const outcome = driveRun(ctx, join(ctx, 'A'), 24);
    expect(outcome.accepted).toBe(true);
    expect(outcome.rank).toBe(1);
    const lapMs = (lapLength / 24) * 1000;
    // Lap 1 starts on the grid, a few metres before the line, like in the game.
    const expected = [lapMs + (toLine / 24) * 1000, lapMs, lapMs];
    expect(outcome.result?.lapsCompleted).toBe(RACE_LAPS);
    outcome.result!.lapTimesMs.forEach((ms, i) => expect(Math.abs(ms - expected[i]!)).toBeLessThan(150));
    expect(outcome.result?.splitsMs).toHaveLength(RACE_LAPS * gatesPerLap);
  });

  it('keeps the best run per player and orders the board by time', () => {
    const ctx = setup();
    const slow = join(ctx, 'Slow');
    const fast = join(ctx, 'Fast');
    driveRun(ctx, slow, 18);
    driveRun(ctx, fast, 25);
    driveRun(ctx, slow, 21);
    const board = ctx.store.toPublic(ctx.session).leaderboard;
    expect(board.map((entry) => entry.name)).toEqual(['Fast', 'Slow']);
    expect(board[1]!.totalMs).toBeLessThan(((lapLength * 3) / 19) * 1000);
    expect(ctx.store.toPublic(ctx.session).results).toHaveLength(3);
  });

  it('ranks a timed-out run below any finished run, by distance covered', () => {
    const ctx = setup();
    const finisher = join(ctx, 'Finisher');
    const twoLaps = join(ctx, 'TwoLaps');
    const oneLap = join(ctx, 'OneLap');
    expect(driveRun(ctx, oneLap, 20, 1).accepted).toBe(true);
    expect(driveRun(ctx, twoLaps, 20, 2).accepted).toBe(true);
    driveRun(ctx, finisher, 15);
    const board = ctx.store.toPublic(ctx.session).leaderboard;
    expect(board.map((entry) => entry.name)).toEqual(['Finisher', 'TwoLaps', 'OneLap']);
    expect(board[1]).toMatchObject({ finished: false, lapsCompleted: 2, totalMs: track.timeLimitMs });
  });

  it('rejects a finish the server did not see', () => {
    const ctx = setup();
    const run = startRun(ctx, join(ctx, 'Early'));
    run.drive(24, toLine + lapLength * 2 + 2);
    expect(run.finish(true)).toMatchObject({ accepted: false, reason: 'the server did not see every lap' });
  });

  it('rejects a car faster than the car can go', () => {
    const ctx = setup();
    const run = startRun(ctx, join(ctx, 'Rocket'));
    run.drive(24, 60);
    run.drive(60, 80);
    run.drive(24, toLine + lapLength * 3);
    expect(run.finish()).toMatchObject({ accepted: false, reason: 'faster than the car can go' });
  });

  it('rejects a jump across the track', () => {
    const ctx = setup();
    const run = startRun(ctx, join(ctx, 'Teleporter'));
    run.drive(20, 40);
    run.pose(geometry.gates[0]!.pos[0], geometry.gates[0]!.pos[1], 0);
    expect(run.finish(false)).toMatchObject({ accepted: false, reason: 'jumped across the track' });
  });

  it('rejects cutting across the grass at road speed', () => {
    const ctx = setup();
    const run = startRun(ctx, join(ctx, 'Cutter'));
    run.drive(24, toLine + 20);
    // Straight at the first checkpoint, through the infield, at full road speed.
    run.straightTo(geometry.gates[0]!.pos, 26);
    expect(run.finish(false)).toMatchObject({ accepted: false, reason: 'faster than the car can go' });
  });

  it('allows a short burst of speed right after a boost box, not a long one', () => {
    const boost = geometry.boosts[0]!;
    // Drives up to the first boost box, which sits on the centreline near the start.
    const runTo = (ctx: ReturnType<typeof setup>, name: string) => {
      const run = startRun(ctx, join(ctx, name));
      let travelled = 0;
      for (;;) {
        run.drive(24, 2);
        travelled += 2;
        const { x, z } = along(run.distance);
        if (Math.hypot(x - boost[0], z - boost[1]) < 1.5 || travelled > 300) break;
      }
      return run;
    };

    const ctx = setup();
    const boosted = runTo(ctx, 'Boosted');
    boosted.drive(37, 30);
    boosted.drive(24, lapLength);
    expect(boosted.finish(false).reason).toBeUndefined();

    // Long enough to run out of boost before the next box comes along.
    const cheat = runTo(ctx, 'Afterburner');
    cheat.drive(37, 300);
    expect(cheat.finish(false)).toMatchObject({ accepted: false, reason: 'faster than the car can go' });
  });

  it('rejects a phone clock that runs ahead of real time', () => {
    const ctx = setup();
    const run = startRun(ctx, join(ctx, 'TimeLord'));
    run.drive(20, 20);
    const at = along(run.distance + 2);
    ctx.advance(100);
    run.pose(at.x, at.z, at.heading, 0.5, 5000);
    expect(run.finish(false)).toMatchObject({ accepted: false, reason: 'clock running ahead of real time' });
  });

  it('rejects driving through a wall', () => {
    const ctx = setup();
    const wall = geometry.walls[0]!;
    const run = startRun(ctx, join(ctx, 'Ghost'));
    const middle: [number, number] = [(wall.a[0] + wall.b[0]) / 2, (wall.a[1] + wall.b[1]) / 2];
    // Start on one side of the wall and step across it, slowly and at ground level.
    run.pose(geometry.spawn[0], geometry.spawn[1], 0);
    for (const x of [middle[0] + 1, middle[0] - 1]) {
      ctx.advance(30_000);
      run.pose(x, middle[1], Math.PI);
    }
    expect(run.finish(false).reason).toMatch(/wall|jumped/);
  });

  it('does not record a run that went nowhere', () => {
    const ctx = setup();
    const run = startRun(ctx, join(ctx, 'Parked'));
    expect(run.finish(false)).toMatchObject({ accepted: false, reason: 'no progress' });
    expect(ctx.store.toPublic(ctx.session).results).toHaveLength(0);
  });

  it('abandons the run when the player disconnects', () => {
    const ctx = setup();
    const player = join(ctx, 'Gone');
    ctx.store.setConnected(ctx.session, player, true);
    ctx.store.startRun(ctx.session, player);
    ctx.store.setConnected(ctx.session, player, false);
    expect(player.run).toBeNull();
    expect(player.state).toBe('lobby');
  });

  it('removes a player together with their results', () => {
    const ctx = setup();
    const player = join(ctx, 'Rude name');
    driveRun(ctx, player, 20);
    ctx.store.removePlayer(ctx.session.code, player.id);
    const view = ctx.store.toPublic(ctx.session);
    expect(view.players).toHaveLength(0);
    expect(view.leaderboard).toHaveLength(0);
  });

  it('does not start runs in a closed session', () => {
    const ctx = setup();
    const player = join(ctx, 'A');
    ctx.store.closeSession(ctx.session.code);
    expect(() => ctx.store.startRun(ctx.session, player)).toThrow('closed');
  });
});

describe('live standing', () => {
  it('places a run in progress among the best runs at the same gate', () => {
    const ctx = setup();
    driveRun(ctx, join(ctx, 'Fast'), 25);
    driveRun(ctx, join(ctx, 'Slow'), 16);

    const me = join(ctx, 'Me');
    const run = startRun(ctx, me);
    expect(ctx.store.standing(ctx.session, me)).toMatchObject({ rank: 0, of: 3 });
    // 20 m/s: slower than Fast, quicker than Slow. Drive until the first checkpoint.
    while (me.run!.referee.splitsMs.length === 0) run.drive(20, 2);
    const standing = ctx.store.standing(ctx.session, me)!;
    expect(standing).toMatchObject({ rank: 2, of: 3 });
    expect(standing.rows.map((row) => [row.rank, row.name, row.you])).toEqual([
      [1, 'Fast', false],
      [2, 'Me', true],
      [3, 'Slow', false],
    ]);
    expect(standing.gapAheadMs).toBeGreaterThan(0);
    expect(standing.gapBehindMs).toBeGreaterThan(0);
  });

  it('keeps the own row when it falls outside the top rows', () => {
    const others: RunResult[] = Array.from({ length: 6 }, (_, i) => ({
      playerId: `p${i}`,
      name: `P${i}`,
      color: '#9247c2',
      finished: true,
      lapsCompleted: RACE_LAPS,
      checkpointsInLap: 0,
      totalMs: 30_000 + i * 1000,
      lapTimesMs: [],
      bestLapMs: null,
      finishedAt: i,
    }));
    // No splits stored: these are treated as evenly paced runs.
    const standing = projectStanding(others, { name: 'Me', color: '#11bba9' }, [60_000], gatesPerLap);
    expect(standing.rank).toBe(7);
    expect(standing.rows.map((row) => row.rank)).toEqual([1, 2, 3, 7]);
    expect(standing.rows.at(-1)?.you).toBe(true);
  });

  it('puts runs that never reached the gate behind', () => {
    const timedOut: RunResult = {
      playerId: 'x',
      name: 'Stalled',
      color: '#f7596c',
      finished: false,
      lapsCompleted: 0,
      checkpointsInLap: 1,
      totalMs: track.timeLimitMs,
      lapTimesMs: [],
      bestLapMs: null,
      splitsMs: [4_000],
      finishedAt: 1,
    };
    const standing = projectStanding([timedOut], { name: 'Me', color: '#11bba9' }, [5_000, 9_000], gatesPerLap);
    expect(standing).toMatchObject({ rank: 1, of: 2, gapBehindMs: null });
  });
});
