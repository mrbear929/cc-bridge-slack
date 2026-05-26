#!/usr/bin/env bash
# Task 3 acceptance test: DM sweep + remove background sweeper thread.
#
# (a) sweep_once() returns (1,0) when a forged stale state file exists,
#     archives the channel, sets slack_archived=true.
# (b) Re-call sweep_once() → returns (0,0) (idempotent).
# (c) archive_sweeper is gone (no thread launch in main.py).
# (d) DM-handler branch responds to "sweep" with "swept N channel(s)".

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/.claude/tools/cc-bridge-state"
TOKEN="$(security find-generic-password -s cc-bridge-slack -a bot-token -w)"

pass=0; fail=0
say() { printf '[%s] %s\n' "$1" "$2"; }
ok()  { say PASS "$1"; pass=$((pass+1)); }
ko()  { say FAIL "$1"; fail=$((fail+1)); }

slack() {
  curl -sS -X POST "https://slack.com/api/$1" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "$2"
}

is_archived() {
  slack conversations.info "channel=$1" \
    | python3 -c "import json,sys; d=json.load(sys.stdin,strict=False); print(str(d.get('channel',{}).get('is_archived', False)).lower())" 2>/dev/null
}

# --- (c) archive_sweeper thread launch is gone --------------------------
say INFO "(c) check archive_sweeper thread launch removed"
if grep -qE 'Thread\(target=archive_sweeper' "$REPO/daemon/main.py"; then
  ko "(c) archive_sweeper thread launch still present"
else
  ok "(c) archive_sweeper thread launch removed"
fi

# Also confirm sweep_once exists
if grep -qE '^def sweep_once' "$REPO/daemon/main.py"; then
  ok "(c) sweep_once function defined"
else
  ko "(c) sweep_once function missing"
fi

# --- (a) sweep_once archives a forged stale state file -------------------
say INFO "(a) sweep_once() archives stale state"
ch=$(slack conversations.create "name=p0b3a-$(date +%s)&is_private=true" | jq -r '.channel.id')
[[ -z "$ch" || "$ch" = "null" ]] && { ko "(a) failed to create test channel"; exit 1; }

sid="p0b3a-$(date +%s)-$$"
jq -nc --arg sid "$sid" --arg ch "$ch" \
  '{session_id:$sid, channel_id:$ch, archived:true,
    archived_at:"2026-01-01T00:00:00Z", archived_by:"test",
    cwd:"/tmp", surface:"obsidian-terminal"}' \
  > "$STATE_DIR/$sid.json"

# Call sweep_once via daemon python
result=$(cd "$REPO/daemon" && uv run python -c "
from main import sweep_once
print(sweep_once(grace_days=0))
" 2>&1 | tail -1)
echo "  sweep_once() returned: $result"

# Accept any (>=1, 0) — there may be pre-existing stale state files; we just
# care that OUR forged one was archived (verified by the channel + state checks
# below).
if echo "$result" | grep -qE '\([1-9][0-9]*, 0\)'; then
  ok "(a) sweep_once returned (>=1, 0): $result"
else
  ko "(a) sweep_once returned unexpected: $result"
fi

# Check channel actually archived
arch=$(is_archived "$ch")
[[ "$arch" = "true" ]] && ok "(a) channel archived in slack" || ko "(a) channel not archived"

# Check state has slack_archived
sa=$(jq -r '.slack_archived // false' "$STATE_DIR/$sid.json")
[[ "$sa" = "true" ]] && ok "(a) state.slack_archived=true" || ko "(a) state.slack_archived=$sa"

# --- (b) sweep_once is idempotent ---------------------------------------
say INFO "(b) sweep_once is idempotent"
result2=$(cd "$REPO/daemon" && uv run python -c "
from main import sweep_once
print(sweep_once(grace_days=0))
" 2>&1 | tail -1)
echo "  sweep_once() returned: $result2"
if echo "$result2" | grep -qE '\(0, 0\)'; then
  ok "(b) sweep_once idempotent: returned (0, 0)"
else
  ko "(b) sweep_once not idempotent: $result2"
fi

# --- (d) DM-handler branch fires sweep_once -----------------------------
# We can't easily call handle_message directly (wrapped in slack_bolt
# decorators). Instead grep verifies the dispatch branch is wired.
say INFO "(d) DM dispatch branch wired"
if grep -qE 'cmd in \("sweep", "cleanup"\)' "$REPO/daemon/main.py"; then
  ok "(d) sweep/cleanup branch present"
else
  ko "(d) sweep/cleanup branch missing"
fi
if grep -qE 'sweep_once\(grace_days=0\)' "$REPO/daemon/main.py"; then
  ok "(d) DM branch calls sweep_once(grace_days=0)"
else
  ko "(d) DM branch doesn't call sweep_once correctly"
fi
if grep -qE 'swept \{archived\} channel' "$REPO/daemon/main.py"; then
  ok "(d) DM branch responds with 'swept N channel(s)'"
else
  ko "(d) DM response template missing"
fi

# Cleanup state file
rm -f "$STATE_DIR/$sid.json"

echo
echo "=== Task 3 results: $pass pass, $fail fail ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
