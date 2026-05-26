#!/usr/bin/env bash
# Task 2 acceptance test: archive on SessionEnd guarded by pending_user_ts.
#
# Three sub-tests:
#   (a) Post-reply /exit → channel archives + tombstone
#   (b) Mid-turn /exit → archive_pending; next Stop drains it
#   (c) From-slack marker → no archive (existing guard)
#
# Solo-driven: forges synthetic state files + pipes payloads to mirror.sh.
# Cleans up its own state files / channels at end.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/.claude/tools/cc-bridge-state"
MIRROR="$REPO/mirror.sh"
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

create_test_channel() {
  local name="$1"
  local resp
  resp="$(slack conversations.create "name=$name&is_private=true")"
  jq -r '.channel.id // empty' <<<"$resp"
}

cleanup_test_channel() {
  local ch="$1"
  slack conversations.archive "channel=$ch" >/dev/null 2>&1 || true
}

last_message_text() {
  # Skip channel-management system messages (archive, join, topic, etc.) so we
  # get the actual last message posted to the channel. Bot-posted messages
  # have subtype=bot_message which we DO want.
  local ch="$1"
  slack conversations.history "channel=$ch&limit=10" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin, strict=False)
SKIP = {'channel_archive','channel_unarchive','channel_join','channel_leave',
        'channel_topic','channel_purpose','channel_name'}
for m in d.get('messages', []):
    if m.get('subtype') not in SKIP:
        print(m.get('text',''))
        break
" 2>/dev/null
}

is_archived() {
  local ch="$1"
  slack conversations.info "channel=$ch" \
    | python3 -c "import json,sys; d=json.load(sys.stdin,strict=False); print(str(d.get('channel',{}).get('is_archived', False)).lower())" 2>/dev/null
}

# --- Test (a): post-reply /exit archives ----------------------------------
say INFO "(a) post-reply /exit → archive immediate"
sid_a="p0b2a-$(date +%s)-$$"
ch_a="$(create_test_channel "p0b2a-$(date +%s)-$$")"
[[ -z "$ch_a" ]] && { ko "(a) failed to create test channel"; exit 1; }

# Forge state: archived not yet, no pending_user_ts (simulates "user typed /exit
# AFTER getting a reply, so Stop already cleared the hourglass")
jq -nc --arg sid "$sid_a" --arg ch "$ch_a" --arg cwd "/tmp" \
  '{session_id:$sid, channel_id:$ch, cwd:$cwd, surface:"obsidian-terminal",
    transcript_path:"/tmp/fake.jsonl", created:"2026-01-01T00:00:00Z"}' \
  > "$STATE_DIR/$sid_a.json"

# Pipe a fake SessionEnd payload to mirror.sh
echo '{"session_id":"'"$sid_a"'","reason":"clear"}' | bash "$MIRROR" end >/dev/null 2>&1

# Verify
sleep 1
arch=$(is_archived "$ch_a")
last=$(last_message_text "$ch_a")
state_arch=$(jq -r '.archived // false' "$STATE_DIR/$sid_a.json")
state_slack_arch=$(jq -r '.slack_archived // false' "$STATE_DIR/$sid_a.json")

[[ "$arch" = "true" ]]                    && ok "(a) channel archived in slack"           || ko "(a) channel NOT archived (got is_archived=$arch)"
[[ "$last" == *"session ended · archived"* ]] && ok "(a) tombstone is last message"          || ko "(a) tombstone missing (last=$last)"
[[ "$state_arch" = "true" ]]              && ok "(a) state.archived=true"                  || ko "(a) state.archived=$state_arch"
[[ "$state_slack_arch" = "true" ]]        && ok "(a) state.slack_archived=true"            || ko "(a) state.slack_archived=$state_slack_arch"

rm -f "$STATE_DIR/$sid_a.json"

# --- Test (b): mid-turn /exit defers, next Stop drains ---------------------
say INFO "(b) mid-turn /exit → archive_pending; next Stop completes archive"
sid_b="p0b2b-$(date +%s)-$$"
ch_b="$(create_test_channel "p0b2b-$(date +%s)-$$")"
[[ -z "$ch_b" ]] && { ko "(b) failed to create test channel"; exit 1; }

# Forge state: pending_user_ts set (user prompt still hanging)
# We need a real ts in the channel for the reaction-swap path; post a placeholder.
post_resp=$(slack chat.postMessage "channel=$ch_b&text=fake+user+prompt")
fake_ts=$(jq -r '.ts // empty' <<<"$post_resp")
slack reactions.add "channel=$ch_b&timestamp=$fake_ts&name=hourglass_flowing_sand" >/dev/null

jq -nc --arg sid "$sid_b" --arg ch "$ch_b" --arg ts "$fake_ts" --arg cwd "/tmp" \
  '{session_id:$sid, channel_id:$ch, pending_user_ts:$ts, cwd:$cwd,
    surface:"obsidian-terminal", transcript_path:"/tmp/fake.jsonl",
    created:"2026-01-01T00:00:00Z"}' \
  > "$STATE_DIR/$sid_b.json"

# Fire SessionEnd → expect deferred (archive_pending=true, NOT archived)
echo '{"session_id":"'"$sid_b"'","reason":"clear"}' | bash "$MIRROR" end >/dev/null 2>&1
sleep 1

arch1=$(is_archived "$ch_b")
ap=$(jq -r '.archive_pending // false' "$STATE_DIR/$sid_b.json")
sa1=$(jq -r '.slack_archived // false' "$STATE_DIR/$sid_b.json")

[[ "$arch1" = "false" ]] && ok "(b) channel NOT archived after deferred end"   || ko "(b) channel archived early (is_archived=$arch1)"
[[ "$ap" = "true" ]]     && ok "(b) state.archive_pending=true"                || ko "(b) archive_pending=$ap (expected true)"
[[ "$sa1" = "false" ]]   && ok "(b) state.slack_archived not yet set"          || ko "(b) slack_archived already true (=$sa1)"

# Now fire a Stop (assistant) hook → should drain archive_pending.
# mirror.sh's extract() reads `.last_assistant_message` for assistant role.
cat <<EOF | bash "$MIRROR" assistant >/dev/null 2>&1
{"session_id":"$sid_b","cwd":"/tmp","transcript_path":"/tmp/fake.jsonl","last_assistant_message":"done"}
EOF
sleep 2

arch2=$(is_archived "$ch_b")
sa2=$(jq -r '.slack_archived // false' "$STATE_DIR/$sid_b.json")
ap2=$(jq -r '.archive_pending // false' "$STATE_DIR/$sid_b.json")

[[ "$arch2" = "true" ]]  && ok "(b) channel archived after Stop drained pending"  || ko "(b) channel NOT archived after Stop (is_archived=$arch2)"
[[ "$sa2" = "true" ]]    && ok "(b) state.slack_archived=true after drain"        || ko "(b) slack_archived=$sa2 (expected true)"
[[ "$ap2" = "false" ]]   && ok "(b) state.archive_pending cleared after drain"    || ko "(b) archive_pending=$ap2 (expected false)"

rm -f "$STATE_DIR/$sid_b.json"

# --- Test (c): from-slack marker → no archive -----------------------------
say INFO "(c) from-slack marker present → end is no-op"
sid_c="p0b2c-$(date +%s)-$$"
ch_c="$(create_test_channel "p0b2c-$(date +%s)-$$")"
[[ -z "$ch_c" ]] && { ko "(c) failed to create test channel"; exit 1; }

jq -nc --arg sid "$sid_c" --arg ch "$ch_c" --arg cwd "/tmp" \
  '{session_id:$sid, channel_id:$ch, cwd:$cwd, surface:"obsidian-terminal",
    transcript_path:"/tmp/fake.jsonl", created:"2026-01-01T00:00:00Z"}' \
  > "$STATE_DIR/$sid_c.json"

mkdir -p "$STATE_DIR/from-slack"
touch "$STATE_DIR/from-slack/$sid_c"

# Fire SessionEnd
echo '{"session_id":"'"$sid_c"'","reason":"clear"}' | bash "$MIRROR" end >/dev/null 2>&1
sleep 1

arch_c=$(is_archived "$ch_c")
state_arch_c=$(jq -r '.archived // false' "$STATE_DIR/$sid_c.json")

[[ "$arch_c" = "false" ]]     && ok "(c) channel NOT archived (marker guard worked)" || ko "(c) channel archived despite marker"
[[ "$state_arch_c" = "false" ]] && ok "(c) state untouched"                            || ko "(c) state.archived was set despite marker"

rm -f "$STATE_DIR/from-slack/$sid_c"
rm -f "$STATE_DIR/$sid_c.json"

# Cleanup all 3 test channels (archive them so they don't pollute)
for ch in "$ch_a" "$ch_b" "$ch_c"; do cleanup_test_channel "$ch"; done

echo
echo "=== Task 2 results: $pass pass, $fail fail ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
