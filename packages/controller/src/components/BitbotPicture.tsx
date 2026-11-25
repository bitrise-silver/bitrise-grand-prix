import { IconBitbot, IconBitbotError, rem } from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';

interface BitbotPictureProps {
  /** Bitbot with crossed-out eyes, for when something did not work. */
  puzzled?: boolean;
}

/**
 * Bitrise's Bitbot, large on a soft purple disc, for a page that has nothing else to show while
 * the player goes back to the QR code. Decorative: the message beside it says what to do.
 */
const BitbotPicture = ({ puzzled = false }: BitbotPictureProps) => {
  const Bitbot = puzzled ? IconBitbotError : IconBitbot;
  return (
    <Box
      alignItems="center"
      aria-hidden
      background="color/purple/minimal"
      borderRadius="full"
      display="flex"
      height={rem(176)}
      justifyContent="center"
      // The page's content is a grid: this centres it in its row.
      justifySelf="center"
      width={rem(176)}
    >
      <Bitbot boxSize="96" color="color/purple/base" />
    </Box>
  );
};

export default BitbotPicture;
