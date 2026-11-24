import { Box } from '@chakra-ui/react/box';
import type { ReactNode } from 'react';

interface PageProps {
  children: ReactNode;
}

/**
 * A page's `<main>`, sliding up and fading in when it opens, so moving between the sessions
 * list, a session, its QR screen and the join page feels like one site. Still for people who
 * ask their system for less motion.
 */
const Page = ({ children }: PageProps) => (
  <Box
    animationDuration="slower"
    animationName="slide-from-bottom, fade-in"
    animationTimingFunction="ease-in-smooth"
    as="main"
    _motionReduce={{ animationName: 'none' }}
  >
    {children}
  </Box>
);

export default Page;
