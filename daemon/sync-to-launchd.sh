#!/usr/bin/env bash
# Sync the daemon source from this git-tracked repo into the launchd-managed
# install at ~/Library/Application Support/cc-bridge-daemon/, then kick the
# service so the new code is live.
#
# Why two locations: launchd agents can't read files inside ~/Documents
# (macOS privacy enforcement). The git repo source stays here for editing
# / version control; the live daemon runs from a launchd-friendly path.

set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/cc-bridge-daemon"

mkdir -p "$DEST"

# Code files only — venv is rebuilt on the dest side
for f in main.py run.sh pyproject.toml uv.lock; do
  cp "$SRC/$f" "$DEST/"
done
chmod +x "$DEST/run.sh"

# Refresh deps (uv is fast — usually <1s if nothing changed)
( cd "$DEST" && uv sync --quiet )

# Restart the daemon so new code is loaded
launchctl kickstart -k "gui/$(id -u)/com.cc-bridge.daemon"

echo "✓ synced to $DEST and kicked launchd"
