#!/usr/bin/env bash
# Lets the autopilot drive the default track headless and prints simulated lap times.
# Use it after changing car physics or a track, then set "minLapMs" in the track file to
# something comfortably below the fastest lap a human could manage.
#
#   ./scripts/measure-laps.sh [seconds-of-simulated-time]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot="${GODOT:-godot}"
seconds="${1:-90}"

"$godot" --headless --path "$root/game" --fixed-fps 60 --quit-after "$((seconds * 60))" -- autopilot 2>&1 | grep "^lap"
