import {
  BitkitButton,
  BitkitEmptyState,
  BitkitTable,
  BitkitTableCard,
  IconMedal,
  IconTrash,
  useResponsive,
} from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { HStack, VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { VisuallyHidden } from '@chakra-ui/react/visually-hidden';
import { formatRaceTime, RACE_LAPS, type LeaderboardEntry } from '@bitrise-grand-prix/shared';

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
            <BitkitTable.Row key={entry.playerId}>
              <BitkitTable.Cell data-label="Rank">{entry.rank}</BitkitTable.Cell>
              <BitkitTable.Cell data-label="Driver">
                <HStack gap="8">
                  {/* The car colour is data from the server, not a design token. */}
                  <Box borderRadius="full" flexShrink="0" height="12" style={{ backgroundColor: entry.color }} width="12" />
                  <Text textStyle="body/md/regular" truncate>
                    {entry.name}
                  </Text>
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
