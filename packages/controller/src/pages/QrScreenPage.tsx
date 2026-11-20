import {
  BitkitAlert,
  BitkitBreadcrumb,
  BitkitButton,
  BitkitContentWrapper,
  BitkitEmptyState,
  BitkitPageHeader,
  BitkitProgressBar,
  BitkitTextInput,
  IconFlag,
} from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { Card } from '@chakra-ui/react/card';
import { QrCode } from '@chakra-ui/react/qr-code';
import { VStack } from '@chakra-ui/react/stack';
import { useEffect, useState, type SyntheticEvent } from 'react';
import { useParams } from 'react-router';
import { JOIN_CODE_ROTATE_MS, type ServerConfig } from '@bitrise-grand-prix/shared';
import { api, ApiError, getScreenKey, joinUrl, setScreenKey } from '../api';
import { useSession } from '../useSession';

const CONTENT_WIDTH = 'layout/maxWidth/960';

interface CurrentCode {
  token: string;
  rotatesAt: number;
  /** Server clock minus this device's clock, so the countdown matches the server. */
  offset: number;
}

/** A phone link carries its screen key in the #fragment; keep it, then take it off the address. */
function takeKeyFromLink(code: string): void {
  const match = /(?:^#|&)key=([^&]+)/.exec(window.location.hash);
  if (!match?.[1]) return;
  setScreenKey(code, decodeURIComponent(match[1]));
  window.history.replaceState(null, '', window.location.pathname + window.location.search);
}

/**
 * The QR code phones scan to join, for its own screen at the booth: typically a phone or a
 * tablet next to the big screen. The code inside changes every few seconds and only the host,
 * or the one device the host gave a phone link to, can see it.
 */
const QrScreenPage = () => {
  const { code = '' } = useParams();
  const { session, error: sessionError, loading } = useSession(code);
  const [config, setConfig] = useState<ServerConfig | null>(null);
  const [current, setCurrent] = useState<CurrentCode | null>(null);
  const [problem, setProblem] = useState<{ status: number; message: string } | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [attempt, setAttempt] = useState(0);
  const [linkRevoked, setLinkRevoked] = useState(false);
  const [awake, setAwake] = useState<boolean | null>(null);
  const [tokenInput, setTokenInput] = useState('');
  const [tokenError, setTokenError] = useState('');
  const [checkingToken, setCheckingToken] = useState(false);

  // Declared before the fetch below, so a freshly opened phone link is used straight away.
  useEffect(() => takeKeyFromLink(code), [code]);

  useEffect(() => {
    api.config().then(setConfig, () => undefined);
  }, []);

  useEffect(() => {
    document.title = session ? `Scan to race · ${session.name}` : 'Bitrise Grand Prix';
  }, [session]);

  const isOpen = session?.status === 'open';

  // Fetch the code for each time slot as it starts.
  useEffect(() => {
    if (!isOpen) return undefined;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const next = await api.joinCode(code);
        if (cancelled) return;
        setCurrent({ token: next.token, rotatesAt: next.rotatesAt, offset: next.serverNow - Date.now() });
        setProblem(null);
        timer = setTimeout(load, Math.max(200, next.rotatesAt - next.serverNow + 50));
      } catch (caught) {
        if (cancelled) return;
        const status = caught instanceof ApiError ? caught.status : 0;
        if (status === 401 && getScreenKey(code)) {
          // The host made a newer phone link, which cancels this one.
          setScreenKey(code, null);
          setLinkRevoked(true);
        }
        setProblem({ status, message: caught instanceof Error ? caught.message : 'Could not get a join code.' });
        setCurrent(null);
        // A locked screen waits to be unlocked; anything else (Wi-Fi dropping out) is worth another try.
        if (status !== 401) timer = setTimeout(load, 3000);
      }
    };
    void load();
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [attempt, code, isOpen]);

  // Ticks the countdown bar.
  useEffect(() => {
    const ticker = setInterval(() => setNow(Date.now()), 100);
    return () => clearInterval(ticker);
  }, []);

  // A phone showing the code must not dim and lock after a minute. Browsers allow this only
  // over HTTPS (or on localhost); elsewhere the page says how to keep the screen on.
  const showingCode = Boolean(isOpen && current);
  useEffect(() => {
    if (!showingCode) return undefined;
    if (!('wakeLock' in navigator)) {
      setAwake(false);
      return undefined;
    }
    let lock: WakeLockSentinel | null = null;
    let cancelled = false;
    const acquire = async () => {
      try {
        const next = await navigator.wakeLock.request('screen');
        if (cancelled) {
          void next.release();
          return;
        }
        lock = next;
        setAwake(true);
      } catch {
        setAwake(false);
      }
    };
    // The lock is dropped whenever the page is hidden; take it again on return.
    const onVisibility = () => {
      if (document.visibilityState === 'visible') void acquire();
    };
    void acquire();
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      cancelled = true;
      document.removeEventListener('visibilitychange', onVisibility);
      void lock?.release();
    };
  }, [showingCode]);

  const unlock = async (event: SyntheticEvent) => {
    event.preventDefault();
    const token = tokenInput.trim();
    if (!token) {
      setTokenError('Enter the admin token.');
      return;
    }
    setCheckingToken(true);
    try {
      // Trade the token for this session's screen key and keep only the key: a phone left
      // showing the code at the booth must not be able to manage sessions.
      setScreenKey(code, await api.createScreenKey(code, token));
      setTokenInput('');
      setTokenError('');
      setLinkRevoked(false);
      setAttempt((value) => value + 1);
    } catch (caught) {
      setTokenError(caught instanceof ApiError && caught.status === 401 ? 'That token is not right.' : 'Could not reach the server.');
    } finally {
      setCheckingToken(false);
    }
  };

  const breadcrumb = (
    <BitkitBreadcrumb>
      <BitkitBreadcrumb.Item href="/">Sessions</BitkitBreadcrumb.Item>
      <BitkitBreadcrumb.Item href={`/session/${encodeURIComponent(code)}`}>{session?.name ?? code}</BitkitBreadcrumb.Item>
      <BitkitBreadcrumb.CurrentItem>QR screen</BitkitBreadcrumb.CurrentItem>
    </BitkitBreadcrumb>
  );

  const remaining = current ? Math.max(0, current.rotatesAt - (now + current.offset)) : 0;
  const url = current && config ? joinUrl(config, code, current.token) : '';

  return (
    <Box as="main">
      <BitkitPageHeader
        breadcrumb={breadcrumb}
        contentWidth={CONTENT_WIDTH}
        secondaryText={session && isOpen ? 'Scan to race' : undefined}
        title={session?.name ?? `Session ${code}`}
      />
      <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
        {sessionError && <BitkitAlert messageText={sessionError} titleText="Could not open this session" variant="critical" />}
        {loading && <BitkitEmptyState bodyText="Connecting to the session." headingText="Loading session" icon={IconFlag} loading />}
        {session && !isOpen && (
          <BitkitAlert
            messageText="Nobody can join a closed session. Reopen it on the session page to show a code here."
            titleText="This session is closed"
            variant="info"
          />
        )}

        {isOpen && problem?.status === 401 && (
          <VStack alignItems="stretch" as="form" gap="16" onSubmit={unlock}>
            <BitkitAlert
              messageText={
                linkRevoked
                  ? 'Another device became this session\'s QR screen. Open a new phone link, or unlock again.'
                  : 'Open a phone link from the session page, or unlock with the admin token. Only a key for showing this session\'s codes stays on this device, and any other QR screen for the session stops.'
              }
              titleText={linkRevoked ? 'This phone link no longer works' : 'Only the host can show the join code'}
              variant="warning"
            />
            <BitkitTextInput
              errorText={tokenError}
              inputProps={{ autoComplete: 'off', type: 'password' }}
              label="Admin token"
              onValueChange={setTokenInput}
              value={tokenInput}
            />
            <BitkitButton alignSelf="flex-start" state={checkingToken ? 'loading' : undefined} type="submit">
              Unlock
            </BitkitButton>
          </VStack>
        )}

        {isOpen && problem && problem.status !== 401 && (
          <BitkitAlert messageText={problem.message} titleText="Could not get a join code. Trying again…" variant="critical" />
        )}

        {isOpen && !problem && (
          <Card.Root elevation justifySelf="center" paddingSize="lg">
            <Card.Body>
              <VStack gap="24">
                {url ? (
                  // As big as the screen allows: half its height on a monitor, its width on a phone.
                  <QrCode.Root css={{ '--qr-code-size': 'min(56vh, 30rem, calc(100vw - 6rem))' }} value={url}>
                    <QrCode.Frame>
                      <QrCode.Pattern />
                    </QrCode.Frame>
                  </QrCode.Root>
                ) : (
                  <BitkitEmptyState bodyText="Getting a join code." headingText="Loading" icon={IconFlag} loading />
                )}
                <BitkitProgressBar
                  label="Time until the code changes"
                  value={(remaining / JOIN_CODE_ROTATE_MS) * 100}
                  width="full"
                />
              </VStack>
            </Card.Body>
          </Card.Root>
        )}

        {showingCode && awake === false && (
          <BitkitAlert
            messageText="This browser cannot keep the screen on here. Turn off auto-lock in the phone's settings while it shows the code."
            titleText="Keep this screen on"
            variant="info"
          />
        )}
      </BitkitContentWrapper>
    </Box>
  );
};

export default QrScreenPage;
