#!/usr/bin/env bash
# Exports the Godot project to game/export/web, which the session server serves at /game/.
# Needs Godot 4 (same minor version as game/project.godot) and its web export templates.
#
#   GODOT=/path/to/godot ./scripts/export-game.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot="${GODOT:-godot}"
out="$root/game/export/web"

if ! command -v "$godot" >/dev/null 2>&1; then
  echo "Godot was not found. Install Godot 4 or set GODOT=/path/to/godot." >&2
  exit 1
fi

mkdir -p "$out"
# The first import builds the texture cache the export reads from.
"$godot" --headless --path "$root/game" --import >/dev/null 2>&1 || true
"$godot" --headless --path "$root/game" --export-release "Web" "$out/index.html"

if [ ! -f "$out/index.wasm" ]; then
  echo "Export failed: $out/index.wasm is missing. Are the web export templates installed?" >&2
  exit 1
fi

# The server sends these instead of compressing a 30+ MB file on every request.
gzip -9 -k -f "$out"/*.wasm "$out"/*.pck "$out"/*.js

echo "Exported to $out"
ls -lh "$out" | awk 'NR>1 {print "  " $5 "\t" $9}'
