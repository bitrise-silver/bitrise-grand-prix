import type {
  JoinCodeResponse,
  JoinResponse,
  JoinTicketResponse,
  PublicSession,
  ScreenKeyResponse,
  ServerConfig,
  SessionSummary,
  TrackInfo,
} from '@bitrise-grand-prix/shared';

const ADMIN_TOKEN_KEY = 'bitrise-grand-prix:admin-token';

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

// Storage can be unavailable (private windows, blocked site data), so every access is guarded.
function readStorage(key: string, storage: 'local' | 'session' = 'local'): string | null {
  try {
    return (storage === 'local' ? window.localStorage : window.sessionStorage).getItem(key);
  } catch {
    return null;
  }
}

function writeStorage(key: string, value: string | null, storage: 'local' | 'session' = 'local'): void {
  try {
    const store = storage === 'local' ? window.localStorage : window.sessionStorage;
    if (value === null) store.removeItem(key);
    else store.setItem(key, value);
  } catch {
    // Nothing to do: the value simply will not be remembered.
  }
}

export const getAdminToken = () => readStorage(ADMIN_TOKEN_KEY);
export const setAdminToken = (token: string | null) => writeStorage(ADMIN_TOKEN_KEY, token);

async function request<T>(path: string, init: RequestInit = {}, admin = false, adminToken?: string): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body) headers.set('content-type', 'application/json');
  const token = adminToken ?? (admin ? getAdminToken() : null);
  if (token) headers.set('authorization', `Bearer ${token}`);

  let response: Response;
  try {
    response = await fetch(path, { ...init, headers });
  } catch {
    throw new ApiError(0, 'Could not reach the server.');
  }
  if (response.status === 204) return undefined as T;
  const body = (await response.json().catch(() => null)) as { error?: string } | null;
  if (!response.ok) throw new ApiError(response.status, body?.error ?? `Request failed (${response.status}).`);
  return body as T;
}

export const api = {
  config: () => request<ServerConfig>('/api/config'),
  tracks: () => request<{ tracks: TrackInfo[] }>('/api/tracks').then((body) => body.tracks),
  checkAdminToken: (token: string) => request<{ ok: true }>('/api/admin/check', {}, true, token),
  listSessions: () => request<{ sessions: SessionSummary[] }>('/api/sessions', {}, true).then((body) => body.sessions),
  createSession: (input: { name: string; trackId: string }) =>
    request<{ session: PublicSession }>('/api/sessions', { method: 'POST', body: JSON.stringify(input) }, true).then(
      (body) => body.session,
    ),
  getSession: (code: string) =>
    request<{ session: PublicSession }>(`/api/sessions/${encodeURIComponent(code)}`).then((body) => body.session),
  closeSession: (code: string) =>
    request<{ session: PublicSession }>(`/api/sessions/${encodeURIComponent(code)}/close`, { method: 'POST' }, true),
  reopenSession: (code: string) =>
    request<{ session: PublicSession }>(`/api/sessions/${encodeURIComponent(code)}/reopen`, { method: 'POST' }, true),
  removePlayer: (code: string, playerId: string) =>
    request<void>(
      `/api/sessions/${encodeURIComponent(code)}/players/${encodeURIComponent(playerId)}`,
      { method: 'DELETE' },
      true,
    ),
  /**
   * The QR screen's current join code. Uses this device's screen key when it has one (the
   * booth's QR phone), the admin token otherwise.
   */
  joinCode: (code: string) => {
    const key = getScreenKey(code);
    return request<JoinCodeResponse>(
      `/api/sessions/${encodeURIComponent(code)}/join-code`,
      key ? { headers: { 'x-screen-key': key } } : {},
      !key,
    );
  },
  /**
   * A key for the device that will show the QR code. Cancels the previous one. Host only:
   * pass `adminToken` to use one that is not stored on this device.
   */
  createScreenKey: (code: string, adminToken?: string) =>
    request<ScreenKeyResponse>(`/api/sessions/${encodeURIComponent(code)}/screen-key`, { method: 'POST' }, true, adminToken).then(
      (body) => body.key,
    ),
  /** Trades a scanned join code for a one-time ticket. */
  exchangeJoinCode: (code: string, token: string) =>
    request<JoinTicketResponse>(`/api/sessions/${encodeURIComponent(code)}/tickets`, {
      method: 'POST',
      body: JSON.stringify({ token }),
    }),
  join: (code: string, name: string, ticket: string) =>
    request<JoinResponse>(`/api/sessions/${encodeURIComponent(code)}/players`, {
      method: 'POST',
      body: JSON.stringify({ name, ticket }),
    }),
};

// --- player identity -----------------------------------------------------------------------------
// The join page stores who the player is; the game (same origin, /game/) reads it back.

export interface StoredPlayer extends JoinResponse {
  code: string;
}

const playerKey = (code: string) => `bitrise-grand-prix:player:${code.toUpperCase()}`;

export function getStoredPlayer(code: string): StoredPlayer | null {
  const raw = readStorage(playerKey(code));
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as StoredPlayer;
    return parsed.token && parsed.playerId ? parsed : null;
  } catch {
    return null;
  }
}

export function storePlayer(code: string, player: JoinResponse | null): void {
  writeStorage(playerKey(code), player ? JSON.stringify({ ...player, code: code.toUpperCase() }) : null);
}

// A ticket lives for this tab only, so a reload while typing a name does not need a new scan.
const ticketKey = (code: string) => `bitrise-grand-prix:ticket:${code.toUpperCase()}`;

export function getStoredTicket(code: string): JoinTicketResponse | null {
  const raw = readStorage(ticketKey(code), 'session');
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as JoinTicketResponse;
    return parsed.ticket && parsed.expiresAt > Date.now() ? parsed : null;
  } catch {
    return null;
  }
}

export function storeTicket(code: string, ticket: JoinTicketResponse | null): void {
  writeStorage(ticketKey(code), ticket ? JSON.stringify(ticket) : null, 'session');
}

/** This site's address as a phone on the network can reach it. */
function siteUrl(config: ServerConfig): string {
  if (config.publicUrl) return config.publicUrl;
  const { protocol, hostname, port } = window.location;
  const isLocal = hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]';
  // A phone cannot open "localhost"; point it at this machine's address on the network instead.
  const host = isLocal && config.lanIp ? config.lanIp : hostname;
  return `${protocol}//${host}${port ? `:${port}` : ''}`;
}

/** The URL phones open, which is what the QR code encodes: the join page plus a join code. */
export const joinUrl = (config: ServerConfig, code: string, token: string) =>
  `${siteUrl(config)}/join/${code}?t=${encodeURIComponent(token)}`;

/** The host's QR screen for a session, meant for its own display at the booth. */
export const qrScreenUrl = (code: string) => `/session/${encodeURIComponent(code)}/qr`;

/**
 * The QR screen with a screen key, for the phone or tablet that shows the code. The key sits
 * in the #fragment, which browsers never send to a server or pass on as a referrer.
 */
export const phoneLinkUrl = (config: ServerConfig, code: string, key: string) =>
  `${siteUrl(config)}${qrScreenUrl(code)}#key=${encodeURIComponent(key)}`;

const screenKeyKey = (code: string) => `bitrise-grand-prix:screen-key:${code.toUpperCase()}`;

export const getScreenKey = (code: string) => readStorage(screenKeyKey(code));
export const setScreenKey = (code: string, key: string | null) => writeStorage(screenKeyKey(code), key);

export const gameUrl = (code: string, spectate = false) =>
  `/game/index.html?s=${encodeURIComponent(code)}${spectate ? '&spectate=1' : ''}`;
