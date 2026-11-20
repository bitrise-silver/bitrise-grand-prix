import {
  BitkitAlert,
  BitkitBadge,
  BitkitButton,
  BitkitContentWrapper,
  BitkitEmptyState,
  BitkitFormDialog,
  BitkitLink,
  BitkitNativeSelect,
  BitkitPageHeader,
  BitkitTable,
  BitkitTextInput,
  IconFlag,
  IconPlus,
  useResponsive,
} from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { VStack } from '@chakra-ui/react/stack';
import { useCallback, useEffect, useState, type FormEvent, type SyntheticEvent } from 'react';
import { useNavigate } from 'react-router';
import {
  DEFAULT_TRACK_ID,
  MAX_SESSION_NAME_LENGTH,
  TRACKS,
  findTrack,
  type ServerConfig,
  type SessionSummary,
} from '@bitrise-grand-prix/shared';
import { api, ApiError, getAdminToken, setAdminToken } from '../api';

const CONTENT_WIDTH = 'layout/maxWidth/1280';

const formatCreated = (timestamp: number) =>
  new Date(timestamp).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });

const SessionsPage = () => {
  const navigate = useNavigate();
  const { isMobile } = useResponsive();

  const [config, setConfig] = useState<ServerConfig | null>(null);
  const [configError, setConfigError] = useState<string | null>(null);
  // True once we know this browser may manage sessions (no token needed, or a valid one is stored).
  const [unlocked, setUnlocked] = useState(false);
  const [tokenInput, setTokenInput] = useState('');
  const [tokenError, setTokenError] = useState('');
  const [checkingToken, setCheckingToken] = useState(false);

  const [sessions, setSessions] = useState<SessionSummary[] | null>(null);
  const [listError, setListError] = useState<string | null>(null);

  const [createOpen, setCreateOpen] = useState(false);
  const [newName, setNewName] = useState('');
  const [newTrack, setNewTrack] = useState(DEFAULT_TRACK_ID);
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  useEffect(() => {
    document.title = 'Bitrise Grand Prix';
    let cancelled = false;
    api
      .config()
      .then(async (loaded) => {
        if (cancelled) return;
        setConfig(loaded);
        if (!loaded.authRequired) {
          setUnlocked(true);
          return;
        }
        const stored = getAdminToken();
        if (!stored) return;
        try {
          await api.checkAdminToken(stored);
          if (!cancelled) setUnlocked(true);
        } catch {
          setAdminToken(null);
        }
      })
      .catch((error: unknown) => {
        if (!cancelled) setConfigError(error instanceof Error ? error.message : 'Could not reach the server.');
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const loadSessions = useCallback(async () => {
    try {
      setSessions(await api.listSessions());
      setListError(null);
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) {
        // The token was changed on the server: ask for it again.
        setAdminToken(null);
        setUnlocked(false);
        return;
      }
      setListError(error instanceof Error ? error.message : 'Could not load sessions.');
    }
  }, []);

  useEffect(() => {
    if (!unlocked) return;
    void loadSessions();
    const timer = setInterval(() => void loadSessions(), 5000);
    return () => clearInterval(timer);
  }, [unlocked, loadSessions]);

  const handleUnlock = async (event: SyntheticEvent) => {
    event.preventDefault();
    const token = tokenInput.trim();
    if (!token) {
      setTokenError('Enter the admin token.');
      return;
    }
    setCheckingToken(true);
    try {
      await api.checkAdminToken(token);
      setAdminToken(token);
      setTokenInput('');
      setTokenError('');
      setUnlocked(true);
    } catch (error) {
      setTokenError(error instanceof ApiError && error.status === 401 ? 'That token is not right.' : 'Could not reach the server.');
    } finally {
      setCheckingToken(false);
    }
  };

  const handleCreate = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setCreating(true);
    setCreateError(null);
    try {
      const session = await api.createSession({ name: newName.trim(), trackId: newTrack });
      setCreateOpen(false);
      void navigate(`/session/${session.code}`);
    } catch (error) {
      setCreateError(error instanceof Error ? error.message : 'Could not create the session.');
    } finally {
      setCreating(false);
    }
  };

  const openCreateDialog = () => {
    setNewName('');
    setNewTrack(DEFAULT_TRACK_ID);
    setCreateError(null);
    setCreateOpen(true);
  };

  const needsToken = Boolean(config?.authRequired) && !unlocked;

  return (
    <Box as="main">
      <BitkitPageHeader
        contentWidth={CONTENT_WIDTH}
        secondaryText="Phone-controlled RC car racing. Create a session, show its QR code, let people race."
        title="Bitrise Grand Prix"
      >
        {unlocked && (
          <BitkitButton icon={IconPlus} onClick={openCreateDialog}>
            New session
          </BitkitButton>
        )}
      </BitkitPageHeader>

      {configError && (
        <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
          <BitkitAlert messageText={configError} titleText="The server is not answering" variant="critical" />
        </BitkitContentWrapper>
      )}

      {needsToken && (
        <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
          <VStack alignItems="stretch" as="form" gap="24" maxWidth="layout/maxWidth/480" onSubmit={handleUnlock}>
            <BitkitTextInput
              errorText={tokenError}
              helperText="Managing sessions on this server needs the admin token (ADMIN_TOKEN)."
              inputProps={{ autoComplete: 'off', type: 'password' }}
              label="Admin token"
              onValueChange={setTokenInput}
              value={tokenInput}
            />
            <BitkitButton alignSelf="flex-start" state={checkingToken ? 'loading' : undefined} type="submit">
              Unlock
            </BitkitButton>
          </VStack>
        </BitkitContentWrapper>
      )}

      {unlocked && (
        <BitkitContentWrapper contentWidth={CONTENT_WIDTH}>
          {config && !config.gameAvailable && (
            <BitkitAlert
              messageText='Run "npm run build:game" on the server so players have something to drive.'
              titleText="The game has not been exported yet"
              variant="warning"
            />
          )}
          {listError && <BitkitAlert messageText={listError} titleText="Could not load sessions" variant="critical" />}

          {sessions === null && !listError && (
            <BitkitEmptyState bodyText="Asking the server for its sessions." headingText="Loading sessions" icon={IconFlag} loading />
          )}

          {sessions?.length === 0 && (
            <BitkitEmptyState
              bodyText="Create one, put its QR code on a screen, and players can join from their phones."
              headingText="No sessions yet"
              icon={IconFlag}
            >
              <BitkitButton icon={IconPlus} onClick={openCreateDialog} size="md" variant="secondary">
                New session
              </BitkitButton>
            </BitkitEmptyState>
          )}

          {sessions && sessions.length > 0 && (
            <BitkitTable.Root layout={isMobile ? 'stacked' : 'table'}>
              <BitkitTable.Header>
                <BitkitTable.Row>
                  <BitkitTable.ColumnHeader>Session</BitkitTable.ColumnHeader>
                  <BitkitTable.ColumnHeader>Code</BitkitTable.ColumnHeader>
                  <BitkitTable.ColumnHeader>Track</BitkitTable.ColumnHeader>
                  <BitkitTable.ColumnHeader>Status</BitkitTable.ColumnHeader>
                  <BitkitTable.ColumnHeader>Players</BitkitTable.ColumnHeader>
                  <BitkitTable.ColumnHeader>Runs</BitkitTable.ColumnHeader>
                  <BitkitTable.ColumnHeader>Created</BitkitTable.ColumnHeader>
                </BitkitTable.Row>
              </BitkitTable.Header>
              <BitkitTable.Body>
                {sessions.map((session) => (
                  <BitkitTable.LinkedRow key={session.code}>
                    <BitkitTable.LinkedRow.LinkCell data-label="Session">
                      <BitkitLink colorVariant="purple" href={`/session/${session.code}`}>
                        {session.name}
                      </BitkitLink>
                    </BitkitTable.LinkedRow.LinkCell>
                    <BitkitTable.Cell data-label="Code">{session.code}</BitkitTable.Cell>
                    <BitkitTable.Cell data-label="Track">{findTrack(session.trackId)?.name ?? session.trackId}</BitkitTable.Cell>
                    <BitkitTable.Cell data-label="Status">
                      <BitkitBadge colorVariant={session.status === 'open' ? 'green' : 'neutral'}>
                        {session.status === 'open' ? 'Open' : 'Closed'}
                      </BitkitBadge>
                    </BitkitTable.Cell>
                    <BitkitTable.Cell data-label="Players">
                      {session.activePlayers} connected, {session.totalPlayers} joined
                    </BitkitTable.Cell>
                    <BitkitTable.Cell data-label="Runs">{session.runs}</BitkitTable.Cell>
                    <BitkitTable.Cell data-label="Created">{formatCreated(session.createdAt)}</BitkitTable.Cell>
                  </BitkitTable.LinkedRow>
                ))}
              </BitkitTable.Body>
            </BitkitTable.Root>
          )}
        </BitkitContentWrapper>
      )}

      <BitkitFormDialog
        footerButtons={
          <>
            <BitkitFormDialog.ActionTrigger asChild>
              <BitkitButton type="button" variant="secondary">
                Cancel
              </BitkitButton>
            </BitkitFormDialog.ActionTrigger>
            <BitkitButton state={creating ? 'loading' : undefined} type="submit">
              Create session
            </BitkitButton>
          </>
        }
        footerContent={createError ? <BitkitAlert messageText={createError} variant="critical" /> : undefined}
        onOpenChange={({ open }) => setCreateOpen(open)}
        onSubmit={handleCreate}
        open={createOpen}
        state={creating ? 'loading' : undefined}
        title="New session"
      >
        <VStack alignItems="stretch" gap="24">
          <BitkitTextInput
            counter
            helperText="Shown on the big screen and on players' phones."
            label="Session name"
            maxLength={MAX_SESSION_NAME_LENGTH}
            onValueChange={setNewName}
            placeholder="Booth, day 1"
            value={newName}
          />
          <BitkitNativeSelect
            helperText={findTrack(newTrack)?.description}
            label="Track"
            onValueChange={setNewTrack}
            value={newTrack}
          >
            {TRACKS.map((track) => (
              <option key={track.id} value={track.id}>
                {track.name}
              </option>
            ))}
          </BitkitNativeSelect>
        </VStack>
      </BitkitFormDialog>
    </Box>
  );
};

export default SessionsPage;
