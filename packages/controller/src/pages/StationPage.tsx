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
import { useEffect, useState, type SyntheticEvent } from 'react';
import { useParams } from 'react-router';
import { findTrack, MAX_NAME_LENGTH, RACE_LAPS } from '@bitrise-grand-prix/shared';
import { api, ApiError, getStationKey, setStationKey, stationGameUrl, storePlayer } from '../api';
import BitbotPicture from '../components/BitbotPicture';
import Leaderboard from '../components/Leaderboard';
import Page from '../components/Page';
import { useSession } from '../useSession';

const CONTENT_WIDTH = 'layout/maxWidth/480';

const LINK_KEY = /(?:^#|&)key=([^&]+)/;

/** The station key from the link this page was opened with, kept on this laptop; else the one kept before. */
function keyFromLink(code: string): string | null {
  const found = LINK_KEY.exec(window.location.hash)?.[1];
  if (!found) return getStationKey(code);
  const key = decodeURIComponent(found);
  setStationKey(code, key);
  return key;
}

/**
 * The booth's laptop station. The host opens its link once on a laptop; from then on each
 * driver types a name here and races with the keyboard, and the game brings them back here
 * when they are done, ready for the next driver.
 */
const StationPage = () => {
  const { code = '' } = useParams();
  const { session, error, loading } = useSession(code);
  const [key, setKey] = useState<string | null>(() => keyFromLink(code));
  const [name, setName] = useState('');
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState('');

  useEffect(() => {
    document.title = session ? `Laptop station · ${session.name}` : 'Laptop station · Bitrise Grand Prix';
  }, [session]);

  useEffect(() => {
    // The key is kept by now; keep it out of the address bar and the history.
    if (LINK_KEY.test(window.location.hash)) {
      window.history.replaceState(null, '', window.location.pathname + window.location.search);
    }
    // Whoever drove last is done: the game must not pick them up again.
    storePlayer(code, null);
  }, [code]);

  const handleJoin = async (event: SyntheticEvent) => {
    event.preventDefault();
    if (!key) return;
    setJoining(true);
    setJoinError('');
    try {
      const ticket = await api.stationTicket(code, key);
      const player = await api.join(code, name.trim(), ticket.ticket);
      storePlayer(code, player);
      window.location.assign(stationGameUrl(code));
    } catch (caught) {
      setJoining(false);
      if (caught instanceof ApiError && caught.status === 401) {
        // The host has made a newer laptop station link since this one.
        setStationKey(code, null);
        setKey(null);
        return;
      }
      setJoinError(caught instanceof Error ? caught.message : 'Could not join. Try again.');
    }
  };

  if (loading || error || !session) {
    return (
      <Page>
        <BitkitPageHeader contentWidth={CONTENT_WIDTH} title="Laptop station" />
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
  const track = findTrack(session.trackId);

  return (
    <Page>
      <BitkitPageHeader
        contentWidth={CONTENT_WIDTH}
        secondaryText={
          track
            ? `Laptop station · ${track.name} · ${RACE_LAPS} laps · ${track.timeLimitMs / 1000} seconds`
            : 'Laptop station'
        }
        title={session.name}
      />
      <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
        {!isOpen && (
          <BitkitAlert
            messageText="Thanks for racing! Here is how it ended."
            titleText="This session is closed"
            variant="info"
          />
        )}

        {isOpen && !key && (
          <>
            <BitkitAlert
              messageText="On the host's session page, press Copy laptop link and open the link on this laptop."
              titleText="This laptop is not a station yet"
              variant="warning"
            />
            <BitbotPicture puzzled />
          </>
        )}

        {isOpen && key && (
          <VStack alignItems="stretch" as="form" gap="16" onSubmit={handleJoin}>
            <BitkitTextInput
              counter
              errorText={joinError}
              // A shared laptop: no suggestions from the drivers before.
              inputProps={{ autoCapitalize: 'words', autoComplete: 'off', autoFocus: true, enterKeyHint: 'go' }}
              label="Driver name"
              maxLength={MAX_NAME_LENGTH}
              onValueChange={setName}
              placeholder="Speedy McShipit"
              value={name}
            />
            <BitkitButton state={joining ? 'loading' : undefined} type="submit">
              Start racing
            </BitkitButton>
            <Text color="text/secondary" textStyle="body/md/regular">
              Drive with W A S D or the arrow keys. Enter starts a run.
            </Text>
          </VStack>
        )}

        <Leaderboard entries={session.leaderboard} limit={5} secondaryText="Top 5, best run per driver" />
      </BitkitContentWrapper>
    </Page>
  );
};

export default StationPage;
