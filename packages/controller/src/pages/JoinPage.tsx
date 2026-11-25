import {
  BitkitAlert,
  BitkitButton,
  BitkitContentWrapper,
  BitkitEmptyState,
  BitkitPageHeader,
  BitkitTextInput,
  IconFlag,
} from '@bitrise/bitkit-v2';
import { VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { useEffect, useRef, useState, type SyntheticEvent } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import {
  findTrack,
  JOIN_TICKET_TTL_MS,
  MAX_NAME_LENGTH,
  RACE_LAPS,
  type JoinTicketResponse,
} from '@bitrise-grand-prix/shared';
import {
  api,
  ApiError,
  gameUrl,
  getStoredPlayer,
  getStoredTicket,
  storePlayer,
  storeTicket,
  type StoredPlayer,
} from '../api';
import BitbotPicture from '../components/BitbotPicture';
import Leaderboard from '../components/Leaderboard';
import Page from '../components/Page';
import { useSession } from '../useSession';

const CONTENT_WIDTH = 'layout/maxWidth/480';

/** Where a phone stands with joining: no code yet, checking the scanned one, or allowed in. */
type Pass = { state: 'none' } | { state: 'expired' } | { state: 'checking' } | { state: 'ready'; ticket: JoinTicketResponse };

const LINK_TICKET = /(?:^#|&)ticket=([^&]+)/;
/** What the server sends a scan to when the code had already run out by the time it arrived. */
const LINK_EXPIRED = '#expired';

/**
 * A ticket in the #fragment: the server puts one there when it trades a scanned code on the
 * phone's first request, and a join link shared from the QR screen carries one too. Keep it
 * like any other ticket. The fragment comes off the address once the page is up.
 */
function ticketFromLink(code: string): JoinTicketResponse | null {
  const ticket = LINK_TICKET.exec(window.location.hash)?.[1];
  if (!ticket) return null;
  // `until` is on the server's clock, which can differ from this phone's; the server decides anyway.
  const until = Number(/(?:^#|&)until=(\d+)/.exec(window.location.hash)?.[1]);
  const found = { ticket: decodeURIComponent(ticket), expiresAt: until > Date.now() ? until : Date.now() + JOIN_TICKET_TTL_MS };
  storeTicket(code, found);
  return found;
}

/**
 * Where the QR code leads. The code in the link works for a few seconds only, so it is traded
 * for a one-time ticket straight away; the player then has a few minutes to pick a name.
 */
const JoinPage = () => {
  const { code = '' } = useParams();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { session, error, loading } = useSession(code);

  const [name, setName] = useState('');
  const [stored, setStored] = useState<StoredPlayer | null>(() => getStoredPlayer(code));
  const [pass, setPass] = useState<Pass>(() => {
    if (searchParams.get('t')) return { state: 'checking' };
    const linked = ticketFromLink(code);
    if (linked) return { state: 'ready', ticket: linked };
    if (window.location.hash === LINK_EXPIRED) return { state: 'expired' };
    const ticket = getStoredTicket(code);
    return ticket ? { state: 'ready', ticket } : { state: 'none' };
  });
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState('');
  const exchanged = useRef(false);

  useEffect(() => {
    document.title = session ? `Join ${session.name} · Bitrise Grand Prix` : 'Bitrise Grand Prix';
  }, [session]);

  // A ticket from the link is stored by now; keep it out of the address bar and the history.
  useEffect(() => {
    if (LINK_TICKET.test(window.location.hash) || window.location.hash === LINK_EXPIRED) {
      window.history.replaceState(null, '', window.location.pathname + window.location.search);
    }
  }, []);

  // The server normally trades a scanned code before this page loads (see above). When it has
  // not, as in development where another server hands out the page, trade it here, once, then
  // drop it from the address bar.
  useEffect(() => {
    const token = searchParams.get('t');
    if (!token || exchanged.current) return;
    exchanged.current = true;
    navigate(`/join/${encodeURIComponent(code)}`, { replace: true });
    api.exchangeJoinCode(code, token).then(
      (ticket) => {
        storeTicket(code, ticket);
        setPass({ state: 'ready', ticket });
      },
      () => setPass({ state: 'expired' }),
    );
  }, [code, navigate, searchParams]);

  // A remembered driver who is no longer in the session (removed by the host) has to join again.
  useEffect(() => {
    if (!session || !stored) return;
    if (!session.players.some((player) => player.id === stored.playerId)) {
      storePlayer(code, null);
      setStored(null);
    }
  }, [code, session, stored]);

  const startRacing = () => window.location.assign(gameUrl(code));

  const handleJoin = async (event: SyntheticEvent) => {
    event.preventDefault();
    if (pass.state !== 'ready') return;
    setJoining(true);
    setJoinError('');
    try {
      const player = await api.join(code, name.trim(), pass.ticket.ticket);
      storeTicket(code, null);
      storePlayer(code, player);
      startRacing();
    } catch (caught) {
      setJoining(false);
      if (caught instanceof ApiError && caught.status === 403) {
        // The ticket ran out or was used: back to scanning.
        storeTicket(code, null);
        setPass({ state: 'expired' });
        return;
      }
      setJoinError(caught instanceof Error ? caught.message : 'Could not join. Try again.');
    }
  };

  if (loading || error || !session) {
    return (
      <Page>
        <BitkitPageHeader contentWidth={CONTENT_WIDTH} title="Bitrise Grand Prix" />
        <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
          {error ? (
            <BitkitAlert messageText={error} titleText="Could not open this session" variant="critical" />
          ) : (
            <BitkitEmptyState bodyText="Finding the session." headingText="Loading" icon={IconFlag} loading />
          )}
        </BitkitContentWrapper>
      </Page>
    );
  }

  const isOpen = session.status === 'open';
  const hasResults = session.leaderboard.length > 0;
  const track = findTrack(session.trackId);
  // About to race (picking a name, or back for another go): the leaderboard is what they are
  // racing for, so it shows even before anyone has finished.
  const canRace = isOpen && (stored !== null || pass.state === 'ready');
  // Nothing to do here but go back to the QR code.
  const mustScan = isOpen && stored === null && (pass.state === 'none' || pass.state === 'expired');

  return (
    <Page>
      <BitkitPageHeader
        contentWidth={CONTENT_WIDTH}
        secondaryText={track ? `${track.name} · ${RACE_LAPS} laps · ${track.timeLimitMs / 1000} seconds` : `${RACE_LAPS} laps`}
        title={session.name}
      />
      <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
        {!isOpen && (
          <BitkitAlert
            messageText={hasResults ? 'Thanks for racing! Here is how it ended.' : 'Nobody can join any more.'}
            titleText="This session is closed"
            variant="info"
          />
        )}

        {isOpen && stored && (
          <VStack alignItems="stretch" gap="16">
            <Text textStyle="body/lg/regular">Welcome back, {stored.name}. Your car is waiting.</Text>
            <BitkitButton onClick={startRacing}>Start racing</BitkitButton>
            <BitkitButton
              onClick={() => {
                storePlayer(code, null);
                setStored(null);
              }}
              variant="tertiary"
            >
              Join as someone else
            </BitkitButton>
          </VStack>
        )}

        {isOpen && !stored && pass.state === 'checking' && (
          <BitkitEmptyState bodyText="Checking the QR code." headingText="Loading" icon={IconFlag} loading />
        )}

        {isOpen && !stored && pass.state === 'none' && (
          <BitkitAlert
            messageText="Point your phone's camera at the QR code on the screen at the track."
            titleText="Scan the QR code to join"
            variant="info"
          />
        )}

        {isOpen && !stored && pass.state === 'expired' && (
          <BitkitAlert
            messageText="The QR code on the screen changes every few seconds, and a shared join link works once. Scan the code on the screen again."
            titleText="That code has expired"
            variant="warning"
          />
        )}

        {mustScan && <BitbotPicture puzzled={pass.state === 'expired'} />}

        {isOpen && !stored && pass.state === 'ready' && (
          <VStack alignItems="stretch" as="form" gap="24" onSubmit={handleJoin}>
            <BitkitTextInput
              counter
              errorText={joinError}
              inputProps={{ autoCapitalize: 'words', autoComplete: 'nickname', enterKeyHint: 'go' }}
              label="Driver name"
              maxLength={MAX_NAME_LENGTH}
              onValueChange={setName}
              placeholder="Speedy McShipit"
              value={name}
            />
            <BitkitButton state={joining ? 'loading' : undefined} type="submit">
              Start racing
            </BitkitButton>
          </VStack>
        )}

        {(canRace || hasResults) && (
          <Leaderboard entries={session.leaderboard} limit={5} secondaryText="Top 5, best run per driver" />
        )}
      </BitkitContentWrapper>
    </Page>
  );
};

export default JoinPage;
