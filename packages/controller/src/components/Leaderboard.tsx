import {
  BitkitBadge,
  BitkitButton,
  BitkitEmptyState,
  BitkitTable,
  BitkitTableCard,
  IconCrown,
  IconMedal,
  IconTrash,
  useResponsive,
} from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { HStack, VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { VisuallyHidden } from '@chakra-ui/react/visually-hidden';
import { useEffect, useRef, useState } from 'react';
import { formatRaceTime, RACE_LAPS, type LeaderboardEntry } from '@bitrise-grand-prix/shared';

/** How long a driver's row stays highlighted after their result changes. */
const FRESH_MS = 6000;

const PODIUM = { 1: 'yellow', 2: 'neutral', 3: 'orange' } as const;

/**
 * Drivers whose result just changed (a first finish, a better run), for a few seconds. Nothing
 * counts as new on the first render, so opening the page does not light up every row.
 */
function useFreshResults(entries: LeaderboardEntry[]): Set<string> {
  const previous = useRef<Map<string, string> | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const [fresh, setFresh] = useState<Set<string>>(() => new Set());

  useEffect(() => {
    const current = new Map(entries.map((entry) => [entry.playerId, `${entry.lapsCompleted}/${entry.totalMs}`]));
    const before = previous.current;
    previous.current = current;
    if (!before) return;
    const changed = [...current].filter(([id, result]) => before.get(id) !== result).map(([id]) => id);
    if (changed.length === 0) return;
    setFresh((ids) => new Set([...ids, ...changed]));
    timers.current.push(
      setTimeout(() => setFresh((ids) => new Set([...ids].filter((id) => !changed.includes(id)))), FRESH_MS),
    );
  }, [entries]);

  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  return fresh;
}

interface LeaderboardProps {
  entries: LeaderboardEntry[];
  /** Shows only the first rows; the phone join page uses a short board. */
  limit?: number;
  /** When given, each row gets a "remove player" action (host only). */
  onRemovePlayer?: (entry: LeaderboardEntry) => void;
  secondaryText?: string;
}

const Leaderboard = ({ entries, limit, onRemovePlayer, secondaryText }: LeaderboardProps) => {
  const { isMobile } = useResponsive();
  const fresh = useFreshResults(entries);
  const rows = limit ? entries.slice(0, limit) : entries;

  if (rows.length === 0) {
    return <BitkitEmptyState bodyText="Finish a run to claim the top spot." headingText="No results yet" icon={IconMedal} />;
  }

  return (
    <BitkitTableCard secondaryText={secondaryText} titleText="Leaderboard">
      <BitkitTable.Root layout={isMobile ? 'stacked' : 'table'} size="md" variant="card">
        <BitkitTable.Header>
          <BitkitTable.Row>
            <BitkitTable.ColumnHeader>#</BitkitTable.ColumnHeader>
            <BitkitTable.ColumnHeader>Driver</BitkitTable.ColumnHeader>
            <BitkitTable.ColumnHeader textAlign="end">Time</BitkitTable.ColumnHeader>
            {onRemovePlayer && (
              <BitkitTable.ColumnHeader>
                <VisuallyHidden>Actions</VisuallyHidden>
              </BitkitTable.ColumnHeader>
            )}
          </BitkitTable.Row>
        </BitkitTable.Header>
        <BitkitTable.Body>
          {rows.map((entry) => (
            <BitkitTable.Row key={entry.playerId} selected={fresh.has(entry.playerId)}>
              <BitkitTable.Cell data-label="Rank">
                {entry.rank in PODIUM ? (
                  <BitkitBadge
                    colorVariant={PODIUM[entry.rank as keyof typeof PODIUM]}
                    icon={entry.rank === 1 ? IconCrown : IconMedal}
                    variant="bold"
                  >
                    {entry.rank}
                  </BitkitBadge>
                ) : (
                  entry.rank
                )}
              </BitkitTable.Cell>
              <BitkitTable.Cell data-label="Driver">
                <HStack gap="8" minWidth="0">
                  {/* The car colour is data from the server, not a design token. */}
                  <Box borderRadius="full" flexShrink="0" height="12" style={{ backgroundColor: entry.color }} width="12" />
                  <Text textStyle="body/md/regular" truncate>
                    {entry.name}
                  </Text>
                  {fresh.has(entry.playerId) && (
                    <BitkitBadge colorVariant="green" flexShrink="0">
                      New
                    </BitkitBadge>
                  )}
                </HStack>
              </BitkitTable.Cell>
              <BitkitTable.Cell data-label="Time" textAlign={isMobile ? 'start' : 'end'}>
                <VStack alignItems={isMobile ? 'flex-start' : 'flex-end'} gap="0">
                  <Text textStyle="code/md">
                    {entry.finished ? formatRaceTime(entry.totalMs) : `${entry.lapsCompleted}/${RACE_LAPS} laps`}
                  </Text>
                  {entry.bestLapMs !== null && (
                    <Text color="text/secondary" textStyle="body/sm/regular">
                      Best lap {formatRaceTime(entry.bestLapMs)}
                    </Text>
                  )}
                </VStack>
              </BitkitTable.Cell>
              {onRemovePlayer &&
                (isMobile ? (
                  <BitkitTable.Cell>
                    <BitkitButton onClick={() => onRemovePlayer(entry)} size="sm" variant="danger-tertiary">
                      Remove player
                    </BitkitButton>
                  </BitkitTable.Cell>
                ) : (
                  <BitkitTable.RowActionsCell
                    actions={[
                      { danger: true, icon: IconTrash, label: 'Remove player', onClick: () => onRemovePlayer(entry) },
                    ]}
                  />
                ))}
            </BitkitTable.Row>
          ))}
        </BitkitTable.Body>
      </BitkitTable.Root>
    </BitkitTableCard>
  );
};

export default Leaderboard;
