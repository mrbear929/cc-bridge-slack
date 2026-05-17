#!/usr/bin/env bash
# cc-bridge-slack/hook-dump.sh
#
# Dump-only hook handler. Saves the raw stdin payload to
# /tmp/cc-hook-dump/<event>-<sid8>-<epochms>.json without doing anything
# else. Used to discover unknown event payload shapes (Notification,
# AskUserQuestion-related events, etc.) by capturing whatever CC fires
# during a normal session.
#
# Usage in settings.json:
#   { "type": "command", "command": "/path/to/hook-dump.sh PreToolUse" }
#
# Inspect:  ls -lat /tmp/cc-hook-dump/ | head
#           jq . /tmp/cc-hook-dump/<file>
#
# Disable:  remove the hook entries from settings.json. Files in
#           /tmp/cc-hook-dump/ are dumped on every fire — clean up
#           manually when done debugging.

set -u

EVENT="${1:-unknown}"
DIR=/tmp/cc-hook-dump
mkdir -p "$DIR" 2>/dev/null

# Read entire stdin then write atomically
PAYLOAD="$(cat)"
SID="$(jq -r '.session_id // "nosession"' <<<"$PAYLOAD" 2>/dev/null)"
SID8="${SID:0:8}"
TS="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')"

printf '%s' "$PAYLOAD" > "$DIR/${EVENT}-${SID8}-${TS}.json"

# Cap directory size: keep newest 200 files
ls -t "$DIR"/*.json 2>/dev/null | tail -n +201 | xargs rm -f 2>/dev/null

exit 0
