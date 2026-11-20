import {
  BitkitAlert,
  BitkitBadge,
  BitkitBreadcrumb,
  BitkitButton,
  BitkitCodeSnippet,
  BitkitContentWrapper,
  BitkitDialog,
  BitkitEmptyState,
  BitkitPageHeader,
  BitkitStat,
  createBitkitToast,
  IconFlag,
  IconOpenInNew,
} from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { HStack, VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { useEffect, useState } from 'react';
import { useParams } from 'react-router';
import { findTrack, type LeaderboardEntry, type ServerConfig } from '@bitrise-grand-prix/shared';
import { api, gameUrl, getAdminToken, phoneLinkUrl, qrScreenUrl } from '../api';
import Leaderboard from '../components/Leaderboard';
import { useSession } from '../useSession';

const CONTENT_WIDTH = 'layout/maxWidth/1616';

/** The host's big screen for one session: the live race and the standings. The QR code has its own screen. */
const SessionPage = () => {
  const { code = '' } = useParams();
  const { session, error, loading, live } = useSession(code);

  const [config, setConfig] = useState<ServerConfig | null>(null);
  const [confirmClose, setConfirmClose] = useState(false);
  const [removing, setRemoving] = useState<LeaderboardEntry | null>(null);
  const [busy, setBusy] = useState(false);
  /** A phone link this browser could not copy, shown so it can be copied by hand. */
  const [shownLink, setShownLink] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .config()
      .then((loaded) => {
        if (!cancelled) setConfig(loaded);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    document.title = session ? `${session.name} · Bitrise Grand Prix` : 'Bitrise Grand Prix';
  }, [session]);

  // Viewing a session is public; changing it needs the admin token when the server asks for one.
  const canManage = config ? !config.authRequired || Boolean(getAdminToken()) : false;
  const lockedReason = canManage ? undefined : 'Unlock with the admin token on the Sessions page first';

  const run = async (action: () => Promise<unknown>, failure: string) => {
    setBusy(true);
    try {
      await action();
      return true;
    } catch (caught) {
      createBitkitToast({ messageText: caught instanceof Error ? caught.message : failure, titleText: failure, variant: 'critical' });
      return false;
    } finally {
      setBusy(false);
    }
  };

  // A link for the phone (or tablet) that shows the QR code at the booth. It goes to the
  // clipboard rather than on screen, because this page is usually the big screen.
  const copyPhoneLink = (sessionCode: string) =>
    run(async () => {
      if (!config) return;
      const link = phoneLinkUrl(config, sessionCode, await api.createScreenKey(sessionCode));
      try {
        await navigator.clipboard.writeText(link);
        createBitkitToast({
          messageText: 'Send it to the phone that will show the QR code, for example by AirDrop or a message to yourself. Any earlier phone link has stopped working.',
          titleText: 'Phone link copied',
          variant: 'success',
        });
      } catch {
        // No clipboard here (plain HTTP on the network, or the browser said no): show it instead.
        setShownLink(link);
      }
    }, 'Could not make a phone link');

  if (loading || error || !session) {
    return (
      <Box as="main">
        <BitkitPageHeader
          breadcrumb={
            <BitkitBreadcrumb>
              <BitkitBreadcrumb.Item href="/">Sessions</BitkitBreadcrumb.Item>
              <BitkitBreadcrumb.CurrentItem>{code}</BitkitBreadcrumb.CurrentItem>
            </BitkitBreadcrumb>
          }
          contentWidth={CONTENT_WIDTH}
          title={`Session ${code}`}
        />
        <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
          {error ? (
            <BitkitAlert messageText={error} titleText="Could not open this session" variant="critical" />
          ) : (
            <BitkitEmptyState bodyText="Connecting to the session." headingText="Loading session" icon={IconFlag} loading />
          )}
        </BitkitContentWrapper>
      </Box>
    );
  }

  const isOpen = session.status === 'open';
  const track = findTrack(session.trackId);

  return (
    <Box as="main">
      <BitkitPageHeader
        badge={<BitkitBadge colorVariant={isOpen ? 'green' : 'neutral'}>{isOpen ? 'Open' : 'Closed'}</BitkitBadge>}
        breadcrumb={
          <BitkitBreadcrumb>
            <BitkitBreadcrumb.Item href="/">Sessions</BitkitBreadcrumb.Item>
            <BitkitBreadcrumb.CurrentItem>{session.name}</BitkitBreadcrumb.CurrentItem>
          </BitkitBreadcrumb>
        }
        contentWidth={CONTENT_WIDTH}
        secondaryText={`${track?.name ?? session.trackId} · code ${session.code}`}
        title={session.name}
      >
        <BitkitButton
          disabledReason={lockedReason}
          onClick={() => void copyPhoneLink(session.code)}
          state={!canManage ? 'disabled' : busy ? 'loading' : undefined}
          variant="secondary"
        >
          Copy phone link
        </BitkitButton>
        <BitkitButton href={qrScreenUrl(session.code)} isExternal suffixIcon={IconOpenInNew} variant="secondary">
          QR screen
        </BitkitButton>
        <BitkitButton href={gameUrl(session.code, true)} isExternal suffixIcon={IconOpenInNew} variant="secondary">
          Race view only
        </BitkitButton>
        {isOpen ? (
          <BitkitButton
            disabledReason={lockedReason}
            onClick={() => setConfirmClose(true)}
            state={canManage ? undefined : 'disabled'}
            variant="danger-secondary"
          >
            Close session
          </BitkitButton>
        ) : (
          <BitkitButton
            disabledReason={lockedReason}
            onClick={() => void run(() => api.reopenSession(session.code), 'Could not reopen the session')}
            state={!canManage ? 'disabled' : busy ? 'loading' : undefined}
          >
            Reopen session
          </BitkitButton>
        )}
      </BitkitPageHeader>

      <BitkitContentWrapper columnTemplate={{ tablet: '1fr 25rem' }} contentWidth={CONTENT_WIDTH}>
        <VStack alignItems="stretch" gap="16">
          {!live && (
            <BitkitAlert
              messageText="Showing the last known standings. Reconnecting on its own."
              titleText="Connection to the server lost"
              variant="warning"
            />
          )}
          {config && !config.gameAvailable ? (
            <BitkitEmptyState
              bodyText='Run "npm run build:game" on the server, then reload this page.'
              headingText="The game has not been exported yet"
              icon={IconFlag}
            />
          ) : (
            <Box asChild aspectRatio="16 / 9" border="none" borderRadius="8" width="full">
              <iframe allow="fullscreen" src={gameUrl(session.code, true)} title={`Live race: ${session.name}`} />
            </Box>
          )}
          {/* Under the race rather than beside it, so the leaderboard can sit right below the QR code. */}
          <HStack alignItems="flex-start" gap="32">
            <BitkitStat label="Connected now" value={String(session.activePlayers)} />
            <BitkitStat label="Drivers" value={String(session.players.length)} />
            <BitkitStat label="Runs" value={String(session.runs)} />
          </HStack>
        </VStack>

        {/* The QR code is on its own screen (see the header), never next to the race view. */}
        <VStack alignItems="stretch" as="aside" gap={{ base: '24', tablet: '32' }}>
          {!isOpen && (
            <BitkitAlert
              messageText="Nobody can join or start a run. The standings below are final unless you reopen it."
              titleText="This session is closed"
              variant="info"
            />
          )}

          <Leaderboard
            entries={session.leaderboard}
            onRemovePlayer={canManage ? setRemoving : undefined}
            secondaryText="Best run per driver"
          />
        </VStack>
      </BitkitContentWrapper>

      <BitkitDialog
        footerButtons={<BitkitButton onClick={() => setShownLink(null)}>Done</BitkitButton>}
        onOpenChange={({ open }) => {
          if (!open) setShownLink(null);
        }}
        open={shownLink !== null}
        size="md"
        title="Phone link"
      >
        <VStack alignItems="stretch" gap="16">
          <Text textStyle="body/md/regular">
            This browser cannot copy here, so copy the link yourself and send it to the phone that will show the QR code.
            Anyone with the link can show join codes for this session, so close this before others can see it.
          </Text>
          {shownLink && <BitkitCodeSnippet variant="single">{shownLink}</BitkitCodeSnippet>}
        </VStack>
      </BitkitDialog>

      <BitkitDialog
        footerButtons={
          <>
            <BitkitButton onClick={() => setConfirmClose(false)} variant="secondary">
              Keep it open
            </BitkitButton>
            <BitkitButton
              onClick={() =>
                void run(() => api.closeSession(session.code), 'Could not close the session').then((done) => {
                  if (done) setConfirmClose(false);
                })
              }
              state={busy ? 'loading' : undefined}
              variant="danger-primary"
            >
              Close session
            </BitkitButton>
          </>
        }
        onOpenChange={({ open }) => setConfirmClose(open)}
        open={confirmClose}
        size="sm"
        state={busy ? 'loading' : undefined}
        title="Close this session?"
      >
        Runs in progress are abandoned and nobody new can join. Results are kept, and you can reopen the session later.
      </BitkitDialog>

      <BitkitDialog
        footerButtons={
          <>
            <BitkitButton onClick={() => setRemoving(null)} variant="secondary">
              Cancel
            </BitkitButton>
            <BitkitButton
              onClick={() => {
                if (!removing) return;
                void run(() => api.removePlayer(session.code, removing.playerId), 'Could not remove the player').then((done) => {
                  if (done) setRemoving(null);
                });
              }}
              state={busy ? 'loading' : undefined}
              variant="danger-primary"
            >
              Remove player
            </BitkitButton>
          </>
        }
        onOpenChange={({ open }) => {
          if (!open) setRemoving(null);
        }}
        open={removing !== null}
        size="sm"
        state={busy ? 'loading' : undefined}
        title={`Remove ${removing?.name ?? 'this player'}?`}
      >
        Their results are deleted and they are disconnected. This cannot be undone.
      </BitkitDialog>
    </Box>
  );
};

export default SessionPage;
