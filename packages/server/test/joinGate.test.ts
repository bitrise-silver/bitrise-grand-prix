import { describe, expect, it } from 'vitest';
import { JOIN_CODE_ROTATE_MS, JOIN_CODE_TTL_MS, JOIN_TICKET_TTL_MS } from '@bitrise-grand-prix/shared';
import { JoinGate } from '../src/joinGate.js';

function gate(start = 1_700_000_000_000) {
  let clock = start;
  return {
    gate: new JoinGate({ now: () => clock }),
    advance: (ms: number) => {
      clock += ms;
    },
  };
}

describe('join codes', () => {
  it('works for its own session while it is fresh', () => {
    const { gate: joinGate } = gate();
    const { token, expiresAt } = joinGate.issue('ABCDE');
    expect(joinGate.verify('ABCDE', token)).toBe(true);
    expect(joinGate.verify('abcde', token)).toBe(true);
    expect(expiresAt - Math.floor(1_700_000_000_000 / JOIN_CODE_ROTATE_MS) * JOIN_CODE_ROTATE_MS).toBe(JOIN_CODE_TTL_MS);
  });

  it('stops working once it is too old', () => {
    const { gate: joinGate, advance } = gate();
    const { token, expiresAt } = joinGate.issue('ABCDE');
    advance(expiresAt - 1_700_000_000_000 - 1);
    expect(joinGate.verify('ABCDE', token)).toBe(true);
    advance(1);
    expect(joinGate.verify('ABCDE', token)).toBe(false);
  });

  it('changes with every rotation, and outlives it so a late scan still works', () => {
    const { gate: joinGate, advance } = gate();
    const first = joinGate.issue('ABCDE');
    expect(first.expiresAt - first.rotatesAt).toBe(JOIN_CODE_TTL_MS - JOIN_CODE_ROTATE_MS);
    advance(first.rotatesAt - 1_700_000_000_000);
    expect(joinGate.issue('ABCDE').token).not.toBe(first.token);
    expect(joinGate.verify('ABCDE', first.token)).toBe(true);
  });

  it('is useless for another session, from another server, or edited', () => {
    const { gate: joinGate } = gate();
    const { token } = joinGate.issue('ABCDE');
    expect(joinGate.verify('ZZZZZ', token)).toBe(false);
    expect(new JoinGate({ now: () => 1_700_000_000_000 }).verify('ABCDE', token)).toBe(false);

    const [stamp, signature] = token.split('.');
    const later = (parseInt(stamp!, 36) + JOIN_CODE_ROTATE_MS).toString(36);
    expect(joinGate.verify('ABCDE', `${later}.${signature}`)).toBe(false);
    expect(joinGate.verify('ABCDE', `${stamp}.${signature!.slice(0, -1)}x`)).toBe(false);
    for (const junk of [undefined, '', '.', 'abc', 42, `${stamp}.`, 'x'.repeat(200)]) {
      expect(joinGate.verify('ABCDE', junk)).toBe(false);
    }
  });

  it('cannot be made for the future', () => {
    const { gate: joinGate } = gate();
    const { token } = joinGate.issue('ABCDE');
    const { gate: early } = gate(1_700_000_000_000 - JOIN_CODE_ROTATE_MS);
    expect(early.verify('ABCDE', token)).toBe(false);
  });
});

describe('join tickets', () => {
  it('are only handed out for a valid code', () => {
    const { gate: joinGate } = gate();
    expect(joinGate.createTicket('ABCDE', 'nope')).toBeNull();
    expect(joinGate.createTicket('ABCDE', joinGate.issue('ABCDE').token)).not.toBeNull();
  });

  it('work once, for one session, for a few minutes', () => {
    const { gate: joinGate, advance } = gate();
    const { ticket } = joinGate.createTicket('ABCDE', joinGate.issue('ABCDE').token)!;
    expect(joinGate.checkTicket('ZZZZZ', ticket)).toBe(false);
    expect(joinGate.checkTicket('ABCDE', ticket)).toBe(true);
    joinGate.consumeTicket(ticket);
    expect(joinGate.checkTicket('ABCDE', ticket)).toBe(false);

    const second = joinGate.createTicket('ABCDE', joinGate.issue('ABCDE').token)!;
    advance(JOIN_TICKET_TTL_MS);
    expect(joinGate.checkTicket('ABCDE', second.ticket)).toBe(false);
  });
});
