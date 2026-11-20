import { useEffect, useState } from 'react';
import type { PublicSession, ServerMessage } from '@bitrise-grand-prix/shared';
import { api, ApiError } from './api';

interface SessionState {
  session: PublicSession | null;
  /** Set when the session could not be loaded at all. */
  error: string | null;
  loading: boolean;
  /** False while the live connection is down; the last known data stays on screen. */
  live: boolean;
}

/**
 * Loads a session and keeps it current over a WebSocket ("watcher" role: session updates only,
 * no car positions). Reconnects on its own with a growing delay.
 */
export function useSession(code: string | undefined): SessionState {
  const [state, setState] = useState<SessionState>({ session: null, error: null, loading: true, live: false });

  useEffect(() => {
    if (!code) return;
    let disposed = false;
    let socket: WebSocket | null = null;
    let retry: ReturnType<typeof setTimeout> | undefined;
    let attempt = 0;

    const connect = () => {
      const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
      socket = new WebSocket(`${protocol}://${window.location.host}/ws?session=${encodeURIComponent(code)}&role=watcher`);
      socket.onopen = () => {
        attempt = 0;
        setState((current) => ({ ...current, live: true }));
      };
      socket.onmessage = (event) => {
        let message: ServerMessage;
        try {
          message = JSON.parse(String(event.data)) as ServerMessage;
        } catch {
          return;
        }
        if (message.t === 'welcome' || message.t === 'session') {
          const { session } = message;
          setState({ session, error: null, loading: false, live: true });
        }
      };
      socket.onclose = () => {
        if (disposed) return;
        setState((current) => ({ ...current, live: false }));
        attempt += 1;
        retry = setTimeout(connect, Math.min(8000, 500 * 2 ** attempt));
      };
    };

    setState({ session: null, error: null, loading: true, live: false });
    api
      .getSession(code)
      .then((session) => {
        if (disposed) return;
        setState((current) => ({ ...current, session, loading: false }));
        connect();
      })
      .catch((error: unknown) => {
        if (disposed) return;
        const message =
          error instanceof ApiError && error.status === 404
            ? 'This session does not exist. It may have been deleted.'
            : error instanceof Error
              ? error.message
              : 'Could not load the session.';
        setState({ session: null, error: message, loading: false, live: false });
      });

    return () => {
      disposed = true;
      clearTimeout(retry);
      socket?.close();
    };
  }, [code]);

  return state;
}
