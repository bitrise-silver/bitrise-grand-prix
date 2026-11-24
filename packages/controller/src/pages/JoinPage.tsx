import {
  BitkitAlert,
  BitkitButton,
  BitkitContentWrapper,
  BitkitEmptyState,
  BitkitList,
  BitkitPageHeader,
  BitkitSectionHeading,
  BitkitTextInput,
  IconFlag,
  IconMobileLandscape,
} from '@bitrise/bitkit-v2';
import { VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { useEffect, useRef, useState, type SyntheticEvent } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import { findTrack, MAX_NAME_LENGTH, RACE_LAPS, RUN_TIME_LIMIT_MS, type JoinTicketResponse } from '@bitrise-grand-prix/shared';
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
import Leaderboard from '../components/Leaderboard';
import Page from '../components/Page';
import { useSession } from '../useSession';

const CONTENT_WIDTH = 'layout/maxWidth/480';

/** Where a phone stands with joining: no code yet, checking the scanned one, or allowed in. */
type Pass = { state: 'none' } | { state: 'expired' } | { state: 'checking' } | { state: 'ready'; ticket: JoinTicketResponse };

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
    const ticket = getStoredTicket(code);
    return ticket ? { state: 'ready', ticket } : { state: 'none' };
  });
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState('');
  const exchanged = useRef(false);

  useEffect(() => {
    document.title = session ? `Join ${session.name} · Bitrise Grand Prix` : 'Bitrise Grand Prix';
  }, [session]);

  // Trade the scanned code for a ticket once, then drop it from the address bar.
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

  return (
    <Page>
      <BitkitPageHeader
        contentWidth={CONTENT_WIDTH}
        secondaryText={`${track?.name ?? 'Bitrise Grand Prix'} · ${RACE_LAPS} laps · ${RUN_TIME_LIMIT_MS / 1000} seconds`}
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
            messageText="The code on the screen changes every few seconds. Scan it again."
            titleText="That QR code has expired"
            variant="warning"
          />
        )}

        {isOpen && !stored && pass.state === 'ready' && (
          <VStack alignItems="stretch" as="form" gap="24" onSubmit={handleJoin}>
            <BitkitTextInput
              counter
              errorText={joinError}
              helperText="Shown on the big screen and the leaderboard."
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

        {/* What the race is like, while they pick a name or wait to scan. */}
        {isOpen && (
          <VStack alignItems="stretch" as="section" gap="16">
            <BitkitSectionHeading icon={IconMobileLandscape} label="How to race" />
            <BitkitList colorVariant="purple" variant="explainer">
              <BitkitList.Item helperText="Left thumb steers, right thumb accelerates. The small button brakes, then reverses.">
                Hold your phone sideways
              </BitkitList.Item>
              <BitkitList.Item helperText="Each one gives you half as much speed again for a second.">
                Drive through the Build Cache boxes
              </BitkitList.Item>
              <BitkitList.Item helperText="A bug halves your speed for a second. So does the grass.">Dodge the bugs</BitkitList.Item>
              <BitkitList.Item
                helperText={`${RACE_LAPS} laps in ${RUN_TIME_LIMIT_MS / 1000} seconds. Your best run counts, so go again as often as you like.`}
              >
                Beat the clock
              </BitkitList.Item>
            </BitkitList>
          </VStack>
        )}

        {/* Nothing to show until someone has finished a run; the join form should be the whole page. */}
        {hasResults && <Leaderboard entries={session.leaderboard} limit={5} secondaryText="Top 5, best run per driver" />}
      </BitkitContentWrapper>
    </Page>
  );
};

export default JoinPage;
