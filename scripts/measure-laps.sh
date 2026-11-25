#!/usr/bin/env bash
# Lets the autopilot drive a track headless and prints simulated lap times.
# Use it after changing car physics or a track, then set "minLapMs" and "timeLimitMs" in the
# track file (see the README's Tracks section).
#
#   ./scripts/measure-laps.sh [seconds-of-simulated-time] [track-id]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot="${GODOT:-godot}"
seconds="${1:-90}"
track="${2:-pipeline-park}"

"$godot" --headless --path "$root/game" --fixed-fps 60 --quit-after "$((seconds * 60))" -- "track=$track" autopilot 2>&1 | grep "^lap"
