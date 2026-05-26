#!/usr/bin/env bash
# Task 4b: full lifecycle of a DM-spawned headless session.
#
# (a) Backtick-wrapped DM body parses correctly (Slack auto-format)
# (b) State file gets headless_origin=true after spawn
# (c) After CC reply lands, channel is renamed (using first_prompt) AND
#     archived (slack_archived=true).
#
# This catches the regressions reported in beta: backticks, no rename,
# no archive.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/.claude/tools/cc-bridge-state"
TEST_CWD="/tmp/cc-bridge-test"
TOKEN="$(security find-generic-password -s cc-bridge-slack -a bot-token -w)"
mkdir -p "$TEST_CWD"

pass=0; fail=0
say() { printf '[%s] %s\n' "$1" "$2"; }
ok()  { say PASS "$1"; pass=$((pass+1)); }
ko()  { say FAIL "$1"; fail=$((fail+1)); }

slack() {
  curl -sS -X POST "https://slack.com/api/$1" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/x-www-form-urlencoded' --data "$2"
}

call_handler() {
  cd "$REPO/daemon" && uv run python -c "
import sys
from main import handle_new_session
print(handle_new_session(sys.argv[1]))
" "$1" 2>&1 | tail -20 | grep -vE '^(Using|Creating|Installed|Resolved|Audited|Built|Reading|warning:)' | tail -1
}

# --- (a) backtick-wrapped DM ---------------------------------------------
say INFO "(a) backtick-wrapped DM body parses"
resp=$(call_handler "\`new $TEST_CWD: respond with the literal word ok\`")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(a) backticks stripped, channel link returned"
else
  ko "(a) backticks broke parsing: $resp"
  exit 1
fi

# Extract channel id + sid from response
ch=$(echo "$resp" | grep -oE 'C[A-Z0-9]+' | head -1)
sid_short=$(echo "$resp" | grep -oE '[0-9a-f]{8}' | head -1)
echo "  channel: $ch  sid_short: $sid_short"

# Find full sid via state file
sleep 2
sid_full=$(ls "$STATE_DIR/${sid_short}"*.json 2>/dev/null | head -1 | sed 's|.*/||; s|.json||')
echo "  sid_full: $sid_full"
if [[ -z "$sid_full" ]]; then
  ko "(a) state file not found for $sid_short"
  exit 1
fi

# --- (b) headless_origin flag set ----------------------------------------
say INFO "(b) headless_origin flag set on state"
ho=$(jq -r '.headless_origin // false' "$STATE_DIR/$sid_full.json")
[[ "$ho" = "true" ]] && ok "(b) headless_origin=true" || ko "(b) headless_origin=$ho"

# --- (c) wait for full lifecycle to complete -----------------------------
say INFO "(c) waiting up to 60s for rename + archive..."
deadline=$(($(date +%s) + 60))
while [[ $(date +%s) -lt $deadline ]]; do
  renamed=$(jq -r '.renamed // false' "$STATE_DIR/$sid_full.json" 2>/dev/null)
  slack_arch=$(jq -r '.slack_archived // false' "$STATE_DIR/$sid_full.json" 2>/dev/null)
  if [[ "$renamed" = "true" && "$slack_arch" = "true" ]]; then break; fi
  sleep 2
done

# State checks
title=$(jq -r '.title // ""' "$STATE_DIR/$sid_full.json")
channel_name=$(jq -r '.channel_name // ""' "$STATE_DIR/$sid_full.json")
[[ "$renamed" = "true" ]]    && ok "(c) state.renamed=true (title=$title)"     || ko "(c) state.renamed=$renamed"
[[ "$channel_name" != "session-${sid_short}" ]] && ok "(c) channel_name changed from placeholder ($channel_name)" || ko "(c) channel_name still placeholder"
[[ "$slack_arch" = "true" ]] && ok "(c) state.slack_archived=true"            || ko "(c) state.slack_archived=$slack_arch"

# Live Slack check
arch_in_slack=$(slack conversations.info "channel=$ch" | python3 -c "import json,sys; d=json.load(sys.stdin,strict=False); print(str(d.get('channel',{}).get('is_archived', False)).lower())" 2>/dev/null)
[[ "$arch_in_slack" = "true" ]] && ok "(c) channel is_archived=true in slack" || ko "(c) channel is_archived=$arch_in_slack in slack"

# Tombstone check (history works on archived channels)
last_msg=$(slack conversations.history "channel=$ch&limit=10" | python3 -c "
import json, sys
d = json.load(sys.stdin, strict=False)
SKIP = {'channel_archive','channel_unarchive','channel_join','channel_leave','channel_topic','channel_purpose','channel_name'}
for m in d.get('messages', []):
    if m.get('subtype') not in SKIP:
        print(m.get('text',''))
        break
" 2>/dev/null)
[[ "$last_msg" == *"session ended · archived"* ]] && ok "(c) tombstone is last message" || ko "(c) tombstone missing (last=$last_msg)"

echo
echo "=== Task 4b results: $pass pass, $fail fail ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
