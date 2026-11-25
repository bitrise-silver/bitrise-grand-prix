import { rem } from '@bitrise/bitkit-v2';
import { Box } from '@chakra-ui/react/box';
import { HStack, VStack } from '@chakra-ui/react/stack';
import { Text } from '@chakra-ui/react/text';
import { useMemo } from 'react';
import { findTrackFile, pointAt, rightOf, tangentAt, trackGeometry, type TrackFile, type Vec2 } from '@bitrise-grand-prix/shared';

interface TrackPreviewProps {
  trackId: string;
}

const LEGEND = [
  { color: 'color/turquoise/base', label: 'Build Cache boxes' },
  { color: 'color/red/base', label: 'Bugs' },
  { color: 'color/yellow/base', label: 'Ramp' },
] as const;

const line = (points: Vec2[], closed = false) =>
  points.map(([x, z], i) => `${i === 0 ? 'M' : 'L'}${x.toFixed(2)} ${z.toFixed(2)}`).join(' ') + (closed ? ' Z' : '');

const add = (p: Vec2, d: Vec2, scale: number): Vec2 => [p[0] + d[0] * scale, p[1] + d[1] * scale];

/** The map is drawn this tall at most, so the dialog it sits in still fits a laptop screen. */
const MAX_HEIGHT = 200;

/** Everything the map draws, worked out once per track from its file. */
function layout(file: TrackFile) {
  const geometry = trackGeometry(file);
  const control = file.centerline.map((point): Vec2 => [point[0] ?? 0, point[1] ?? 0]);
  const placed = (item: { at: number; offset: number }) => add(pointAt(control, item.at), rightOf(tangentAt(control, item.at)), item.offset);
  const start = pointAt(control, 0);
  const ahead = tangentAt(control, 0);
  const across = rightOf(ahead);
  const half = geometry.roadHalf;

  // Frame what is drawn, not the whole arena, which is mostly empty grass round the edges.
  const reach = file.roadWidth / 2 + 3;
  const xs: number[] = [];
  const zs: number[] = [];
  const include = ([x, z]: Vec2, pad: number) => {
    xs.push(x - pad, x + pad);
    zs.push(z - pad, z + pad);
  };
  geometry.path.forEach((p) => include(p, reach));
  (file.shortcuts ?? []).forEach((shortcut) => shortcut.points.forEach((p) => include([p[0] ?? 0, p[1] ?? 0], shortcut.width / 2 + 3)));
  (file.walls ?? []).forEach((wall) => [wall.from, wall.to].forEach((p) => include([p[0] ?? 0, p[1] ?? 0], 3)));
  const left = Math.max(Math.min(...xs), -geometry.arena.halfWidth);
  const top = Math.max(Math.min(...zs), -geometry.arena.halfDepth);
  const right = Math.min(Math.max(...xs), geometry.arena.halfWidth);
  const bottom = Math.min(Math.max(...zs), geometry.arena.halfDepth);

  return {
    frame: { x: left, z: top, width: right - left, depth: bottom - top },
    roadWidth: file.roadWidth,
    road: line(geometry.path, true),
    shortcuts: (file.shortcuts ?? []).map((shortcut) => ({ d: line(shortcut.points.map((p): Vec2 => [p[0] ?? 0, p[1] ?? 0])), width: shortcut.width })),
    walls: (file.walls ?? []).map((wall) => line([[wall.from[0] ?? 0, wall.from[1] ?? 0], [wall.to[0] ?? 0, wall.to[1] ?? 0]])),
    ramps: (file.ramps ?? []).map((ramp) => {
      const heading = (ramp.headingDeg * Math.PI) / 180;
      const along: Vec2 = [Math.cos(heading), Math.sin(heading)];
      const side = rightOf(along);
      const base: Vec2 = [ramp.pos[0] ?? 0, ramp.pos[1] ?? 0];
      const top = add(base, along, ramp.length);
      return line([add(base, side, -ramp.width / 2), add(base, side, ramp.width / 2), add(top, side, ramp.width / 2), add(top, side, -ramp.width / 2)], true);
    }),
    boosts: geometry.boosts,
    bugs: (file.obstacles ?? []).map(placed),
    finish: line([add(start, across, -half), add(start, across, half)]),
    // An arrow just past the line, pointing the way the cars go.
    arrow: line([add(start, ahead, 8), add(add(start, ahead, 3.5), across, 2.6), add(add(start, ahead, 3.5), across, -2.6)], true),
  };
}

/**
 * A small map of a track, as the cameras see it (north at the top): the road with the start
 * line and the driving direction, the shortcut, the ramp and the wall it jumps, and where the
 * boost and bug boxes are.
 */
const TrackPreview = ({ trackId }: TrackPreviewProps) => {
  const file = findTrackFile(trackId);
  const map = useMemo(() => (file ? layout(file) : null), [file]);
  if (!file || !map) return null;

  const { frame } = map;
  return (
    <VStack alignItems="stretch" gap="8">
      <Box
        alignSelf="center"
        asChild
        aspectRatio={`${frame.width} / ${frame.depth}`}
        border="1px solid"
        borderColor="border/minimal"
        borderRadius="8"
        maxWidth={rem(Math.round((MAX_HEIGHT * frame.width) / frame.depth))}
        width="full"
      >
        <svg aria-label={`Map of ${file.name}`} role="img" viewBox={`${frame.x} ${frame.z} ${frame.width} ${frame.depth}`}>
          <Box asChild color="color/green/minimal">
            <rect fill="currentColor" height={frame.depth} width={frame.width} x={frame.x} y={frame.z} />
          </Box>
          {/* A pale edge round the road and the shortcut, then the asphalt on top. */}
          <Box asChild color="background/primary">
            <g fill="none" strokeLinecap="round" strokeLinejoin="round">
              <path d={map.road} stroke="currentColor" strokeWidth={map.roadWidth + 2} />
              {map.shortcuts.map((shortcut) => (
                <path d={shortcut.d} key={shortcut.d} stroke="currentColor" strokeWidth={shortcut.width + 2} />
              ))}
            </g>
          </Box>
          <Box asChild color="color/purple/strong">
            <g fill="none" strokeLinecap="round" strokeLinejoin="round">
              <path d={map.road} stroke="currentColor" strokeWidth={map.roadWidth} />
              {map.shortcuts.map((shortcut) => (
                <path d={shortcut.d} key={shortcut.d} stroke="currentColor" strokeWidth={shortcut.width} />
              ))}
            </g>
          </Box>
          <Box asChild color="color/neutral/strong">
            <g fill="none" strokeLinecap="round">
              {map.walls.map((wall) => (
                <path d={wall} key={wall} stroke="currentColor" strokeWidth={1.6} />
              ))}
            </g>
          </Box>
          <Box asChild color="color/yellow/base">
            <g>
              {map.ramps.map((ramp) => (
                <path d={ramp} fill="currentColor" key={ramp} />
              ))}
            </g>
          </Box>
          {/* The start line, chequered, and the way round. */}
          <Box asChild color="background/primary">
            <g>
              <path d={map.finish} fill="none" stroke="currentColor" strokeWidth={2.4} />
              <path d={map.arrow} fill="currentColor" />
            </g>
          </Box>
          <Box asChild color="text/primary">
            <path d={map.finish} fill="none" stroke="currentColor" strokeDasharray="1.25 1.25" strokeWidth={2.4} />
          </Box>
          <Box asChild color="color/turquoise/base">
            <g>
              {map.boosts.map(([x, z]) => (
                <circle cx={x} cy={z} fill="currentColor" key={`${x},${z}`} r={1.8} />
              ))}
            </g>
          </Box>
          <Box asChild color="color/red/base">
            <g>
              {map.bugs.map(([x, z]) => (
                <circle cx={x} cy={z} fill="currentColor" key={`${x},${z}`} r={1.8} />
              ))}
            </g>
          </Box>
        </svg>
      </Box>
      <HStack columnGap="16" flexWrap="wrap" justifyContent="center" rowGap="4">
        {LEGEND.map((item) => (
          <HStack gap="6" key={item.label}>
            <Box background={item.color} borderRadius="full" flexShrink="0" height="8" width="8" />
            <Text color="text/secondary" textStyle="body/sm/regular">
              {item.label}
            </Text>
          </HStack>
        ))}
      </HStack>
    </VStack>
  );
};

export default TrackPreview;
