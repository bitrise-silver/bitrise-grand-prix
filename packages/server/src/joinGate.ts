import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { JOIN_CODE_ROTATE_MS, JOIN_CODE_TTL_MS, JOIN_TICKET_TTL_MS } from '@bitrise-grand-prix/shared';

// Joining a session takes two steps, so that only someone standing in front of the QR
// screen can join:
//
//  1. The QR screen (host only) shows a join code that changes every JOIN_CODE_ROTATE_MS. A
//     code is the time it was made plus a signature over that time and the session: nobody
//     without the server's secret can make one, and it stops working after JOIN_CODE_TTL_MS.
//  2. The phone trades the code for a ticket straight away, then has a few minutes to type a
//     name. A ticket works once.

const MAX_TICKETS = 5000;

export interface JoinGateOptions {
  /** Signs join codes. A fresh random one per process is fine: codes live seconds. */
  secret?: Buffer;
  now?: () => number;
}

export class JoinGate {
  private readonly secret: Buffer;
  private readonly now: () => number;
  private readonly tickets = new Map<string, { code: string; expiresAt: number }>();

  constructor(options: JoinGateOptions = {}) {
    this.secret = options.secret ?? randomBytes(32);
    this.now = options.now ?? Date.now;
  }

  /** The join code for the current time slot. Every QR screen shows the same one. */
  issue(sessionCode: string): { token: string; rotatesAt: number; expiresAt: number } {
    const issuedAt = Math.floor(this.now() / JOIN_CODE_ROTATE_MS) * JOIN_CODE_ROTATE_MS;
    return {
      token: `${issuedAt.toString(36)}.${this.sign(sessionCode, issuedAt)}`,
      rotatesAt: issuedAt + JOIN_CODE_ROTATE_MS,
      expiresAt: issuedAt + JOIN_CODE_TTL_MS,
    };
  }

  /** True for a code this server made for this session in the last JOIN_CODE_TTL_MS. */
  verify(sessionCode: string, token: unknown): boolean {
    if (typeof token !== 'string' || token.length > 64) return false;
    const [stamp, signature] = token.split('.');
    if (!stamp || !signature || !/^[0-9a-z]{1,12}$/.test(stamp)) return false;
    const issuedAt = parseInt(stamp, 36);
    const age = this.now() - issuedAt;
    if (!Number.isSafeInteger(issuedAt) || age < 0 || age >= JOIN_CODE_TTL_MS) return false;
    const expected = Buffer.from(this.sign(sessionCode, issuedAt));
    const given = Buffer.from(signature);
    return expected.length === given.length && timingSafeEqual(expected, given);
  }

  /** Trades a valid join code for a one-time ticket, or returns null. */
  createTicket(sessionCode: string, token: unknown): { ticket: string; expiresAt: number } | null {
    if (!this.verify(sessionCode, token)) return null;
    this.prune();
    if (this.tickets.size >= MAX_TICKETS) return null;
    const ticket = randomBytes(18).toString('base64url');
    const expiresAt = this.now() + JOIN_TICKET_TTL_MS;
    this.tickets.set(ticket, { code: sessionCode.toUpperCase(), expiresAt });
    return { ticket, expiresAt };
  }

  /** True if `ticket` is valid for the session right now. Does not use it up. */
  checkTicket(sessionCode: string, ticket: unknown): boolean {
    if (typeof ticket !== 'string') return false;
    const entry = this.tickets.get(ticket);
    return Boolean(entry && entry.code === sessionCode.toUpperCase() && entry.expiresAt > this.now());
  }

  /** Uses a ticket up. */
  consumeTicket(ticket: string): void {
    this.tickets.delete(ticket);
  }

  private sign(sessionCode: string, issuedAt: number): string {
    return createHmac('sha256', this.secret).update(`${sessionCode.toUpperCase()}|${issuedAt}`).digest('base64url').slice(0, 22);
  }

  private prune(): void {
    const now = this.now();
    for (const [ticket, entry] of this.tickets) if (entry.expiresAt <= now) this.tickets.delete(ticket);
  }
}
