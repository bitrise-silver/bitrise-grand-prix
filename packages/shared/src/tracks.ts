// Track files live in game/tracks so the Godot project stays self-contained. The server reads
// the same files: their metadata for the site, and their geometry to referee runs.

import codeSigningCircuit from '../../../game/tracks/code-signing-circuit.json';
import hotfixHairpins from '../../../game/tracks/hotfix-hairpins.json';
import mergeConflictMile from '../../../game/tracks/merge-conflict-mile.json';
import monorepoMeander from '../../../game/tracks/monorepo-meander.json';
import pipelinePark from '../../../game/tracks/pipeline-park.json';
import releaseTrainRing from '../../../game/tracks/release-train-ring.json';

export interface TrackInfo {
  id: string;
  name: string;
  description: string;
  /** Number of checkpoint gates per lap, not counting the finish line. */
  checkpoints: number;
  /** A lap faster than this is physically impossible and marks the run as invalid. */
  minLapMs: number;
  /** A run ends this long after GO if it has not finished, and a slower finish does not count. */
  timeLimitMs: number;
}

/** A track file as stored in game/tracks (see the README for what each field means). */
export interface TrackFile {
  id: string;
  name: string;
  description: string;
  roadWidth: number;
  minLapMs: number;
  timeLimitMs: number;
  arena: { halfWidth: number; halfDepth: number };
  centerline: number[][];
  checkpoints: number[];
  shortcuts?: { width: number; points: number[][] }[];
  ramps?: { pos: number[]; headingDeg: number; length: number; width: number; angleDeg: number }[];
  walls?: { from: number[]; to: number[]; height: number; label?: string }[];
  boosts?: { at: number; offset: number }[];
  obstacles?: { at: number; offset: number }[];
}

function toInfo(file: TrackFile): TrackInfo {
  return {
    id: file.id,
    name: file.name,
    description: file.description,
    checkpoints: file.checkpoints.length,
    minLapMs: file.minLapMs,
    timeLimitMs: file.timeLimitMs,
  };
}

/**
 * Add a track: drop a JSON file in game/tracks, import it here and add it. The site lists them in
 * this order, roughly easiest first.
 */
export const TRACK_FILES: TrackFile[] = [
  pipelinePark,
  releaseTrainRing,
  monorepoMeander,
  mergeConflictMile,
  codeSigningCircuit,
  hotfixHairpins,
];

export const TRACKS: TrackInfo[] = TRACK_FILES.map(toInfo);

export const DEFAULT_TRACK_ID = pipelinePark.id;

export function findTrack(id: string): TrackInfo | undefined {
  return TRACKS.find((track) => track.id === id);
}

export function findTrackFile(id: string): TrackFile | undefined {
  return TRACK_FILES.find((track) => track.id === id);
}
