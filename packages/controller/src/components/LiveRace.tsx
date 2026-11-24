import { BitkitBadge, BitkitIconButton, IconDot, IconFullscreen } from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { HStack, VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { useRef } from 'react';

interface LiveRaceProps {
  /** False while the connection to the server is down. */
  live: boolean;
  src: string;
  title: string;
  /** Shown beside the live badge, e.g. the track and how many are driving. */
  caption: string;
}

/**
 * The 3D race view on the session page, with a pulsing live badge and a button that puts the
 * race on the whole screen, for the big screen at the booth.
 */
const LiveRace = ({ caption, live, src, title }: LiveRaceProps) => {
  const frame = useRef<HTMLIFrameElement>(null);
  // Phones (iPhone Safari in particular) cannot put an element full screen; offer it only where it works.
  const canFullscreen = typeof document !== 'undefined' && Boolean(document.fullscreenEnabled);

  return (
    <VStack alignItems="stretch" gap="8">
      <HStack gap="12" justifyContent="space-between" minHeight="40">
        <HStack gap="8" minWidth="0">
          <BitkitBadge
            animation={live ? 'pulse' : undefined}
            colorVariant={live ? 'red' : 'neutral'}
            icon={IconDot}
            variant="bold"
            _motionReduce={{ animation: 'none' }}
          >
            {live ? 'Live' : 'Reconnecting'}
          </BitkitBadge>
          <Text color="text/secondary" textStyle="body/md/regular" truncate>
            {caption}
          </Text>
        </HStack>
        {canFullscreen && (
          <BitkitIconButton
            icon={IconFullscreen}
            label="Show the race full screen"
            onClick={() => void frame.current?.requestFullscreen().catch(() => undefined)}
            size="md"
            variant="secondary"
          />
        )}
      </HStack>
      <Box asChild aspectRatio="16 / 9" border="none" borderRadius="8" width="full">
        <iframe allow="fullscreen" ref={frame} src={src} title={title} />
      </Box>
    </VStack>
  );
};

export default LiveRace;
