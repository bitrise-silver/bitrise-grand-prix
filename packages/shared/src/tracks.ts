// Track files live in game/tracks so the Godot project stays self-contained. The server reads
// the same files: their metadata for the site, and their geometry to referee runs.

import pipelinePark from '../../../game/tracks/pipeline-park.json';

export interface TrackInfo {
  id: string;
  name: string;
  description: string;
  /** Number of checkpoint gates per lap, not counting the finish line. */
  checkpoints: number;
  /** A lap faster than this is physically impossible and marks the run as invalid. */
  minLapMs: number;
}

/** A track file as stored in game/tracks (see the README for what each field means). */
export interface TrackFile {
  id: string;
  name: string;
  description: string;
  roadWidth: number;
  minLapMs: number;
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
  };
}

/** Add a track: drop a JSON file in game/tracks, import it here and append it. */
export const TRACK_FILES: TrackFile[] = [pipelinePark];

export const TRACKS: TrackInfo[] = TRACK_FILES.map(toInfo);

export const DEFAULT_TRACK_ID = pipelinePark.id;

export function findTrack(id: string): TrackInfo | undefined {
  return TRACKS.find((track) => track.id === id);
}

export function findTrackFile(id: string): TrackFile | undefined {
  return TRACK_FILES.find((track) => track.id === id);
}
