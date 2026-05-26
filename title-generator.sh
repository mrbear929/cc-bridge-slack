#!/usr/bin/env bash
# cc-bridge-slack/title-generator.sh
#
# Single-pass title mirror. Reads the title CC has already generated
# (terminal CC: `ai-title` line in transcript jsonl; Claudian: meta.json),
# renames the Slack channel, sets the topic, marks state.renamed=true.
#
# Called from mirror.sh in the background after every assistant Stop
# while state.renamed is false. No Bedrock calls. No polling — the
# caller re-fires on subsequent Stops if the title hasn't landed yet.
#
# Usage: title-generator.sh <session_id>

set -u

SID="${1:-}"
[[ -z "$SID" ]] && exit 0

ENV_FILE="${SLACK_BRIDGE_ENV:-$HOME/.claude/tools/slack-bridge.env}"
LOG_FILE="${MIRROR_LOG:-/tmp/cc-mirror-test.log}"
STATE_DIR="${MIRROR_STATE_DIR:-$HOME/.claude/tools/cc-bridge-state}"
STATE_FILE="$STATE_DIR/$SID.json"

log() { printf '[%s] [title-gen %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${SID:0:8}" "$*" >>"$LOG_FILE"; }

[[ -f "$STATE_FILE" ]] || { log "no state file"; exit 0; }
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
  SLACK_BOT_TOKEN="$(security find-generic-password -s cc-bridge-slack -a bot-token -w 2>/dev/null || true)"
fi

RENAMED="$(jq -r '.renamed // false' "$STATE_FILE")"
[[ "$RENAMED" = "true" ]] && exit 0

CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
CWD="$(jq -r '.cwd // empty' "$STATE_FILE")"
SURFACE="$(jq -r '.surface // empty' "$STATE_FILE")"
TRANSCRIPT="$(jq -r '.transcript_path // empty' "$STATE_FILE")"

if [[ -z "$CHANNEL_ID" ]]; then
  log "missing channel_id"
  exit 0
fi

# === Source 1: Claudian meta.json (Claudian SDK fork) ===
TITLE_FULL=""
if [[ "$SURFACE" = "obsidian-claudian" && -d "$CWD/.claudian/sessions" ]]; then
  META=$(grep -lF "\"sessionId\": \"$SID\"" "$CWD"/.claudian/sessions/*.meta.json 2>/dev/null | head -1)
  if [[ -n "$META" ]]; then
    STATUS=$(jq -r '.titleGenerationStatus // empty' "$META" 2>/dev/null)
    CANDIDATE=$(jq -r '.title // empty' "$META" 2>/dev/null)
    if [[ "$STATUS" = "success" && -n "$CANDIDATE" && "$CANDIDATE" != "Start a new conversation" ]]; then
      TITLE_FULL="$CANDIDATE"
      log "found Claudian title: $TITLE_FULL"
    fi
  fi
fi

# === Source 2: ai-title in transcript jsonl (terminal CC + every other surface) ===
# CC writes lines like {"type":"ai-title","aiTitle":"...","sessionId":"<sid>"}
# whenever it generates/updates a title. Take the last one for this sid.
if [[ -z "$TITLE_FULL" && -f "$TRANSCRIPT" ]]; then
  CANDIDATE=$(jq -r --arg sid "$SID" '
    select(.type == "ai-title" and .sessionId == $sid) | .aiTitle
  ' "$TRANSCRIPT" 2>/dev/null | tail -1)
  if [[ -n "$CANDIDATE" ]]; then
    TITLE_FULL="$CANDIDATE"
    log "found ai-title in transcript: $TITLE_FULL"
  fi
fi

# === Source 3: headless_origin fallback (DM `new <path>: <prompt>` spawns) ===
# `claude -p` does not generate ai-title. Without this fallback, headless-spawned
# channels keep the placeholder name forever. Use the first prompt as a slug.
HEADLESS_ORIGIN="$(jq -r '.headless_origin // false' "$STATE_FILE" 2>/dev/null)"
if [[ -z "$TITLE_FULL" && "$HEADLESS_ORIGIN" = "true" ]]; then
  FIRST_PROMPT="$(jq -r '.first_prompt // empty' "$STATE_FILE" 2>/dev/null)"
  if [[ -n "$FIRST_PROMPT" ]]; then
    # Truncate to first 60 chars; sentence-case-ish so it reads OK as a name
    TITLE_FULL="$(printf '%s' "$FIRST_PROMPT" | head -c 60)"
    log "using first_prompt as headless title: $TITLE_FULL"
  fi
fi

# Title not generated yet by either source. Exit quietly — next Stop
# will retry.
if [[ -z "$TITLE_FULL" ]]; then
  log "no title yet (will retry on next Stop)"
  exit 0
fi

# Slug for channel name: lowercase, [a-z0-9]+, ≤70 chars (Slack max 80, headroom for collision suffix)
NEW_NAME="$(printf '%s' "$TITLE_FULL" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-70)"

if [[ -z "$NEW_NAME" ]]; then
  log "slug empty for title='$TITLE_FULL'"
  exit 0
fi

# Try rename with -2/-3/-4 suffix on name_taken collision
FINAL_NAME=""
RESP=""
for suffix in '' '-2' '-3' '-4'; do
  TRY_NAME="${NEW_NAME}${suffix}"
  RESP="$(curl -sS -X POST https://slack.com/api/conversations.rename \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$(jq -nc --arg ch "$CHANNEL_ID" --arg n "$TRY_NAME" '{channel:$ch, name:$n}')" 2>>"$LOG_FILE")"
  OK="$(jq -r '.ok' <<<"$RESP" 2>/dev/null)"
  if [[ "$OK" = "true" ]]; then
    FINAL_NAME="$TRY_NAME"
    break
  fi
  ERR="$(jq -r '.error // ""' <<<"$RESP")"
  [[ "$ERR" != "name_taken" ]] && break
done

if [[ -z "$FINAL_NAME" ]]; then
  log "rename failed: $RESP"
  exit 0
fi

TMP="$(mktemp)"
jq --arg n "$FINAL_NAME" --arg t "$TITLE_FULL" \
  '.channel_name=$n | .title=$t | .renamed=true' \
  "$STATE_FILE" >"$TMP" && mv "$TMP" "$STATE_FILE"
log "renamed to $FINAL_NAME (title='$TITLE_FULL')"

# Replace topic with the human-readable title + cwd
CWD_TOPIC="$(jq -r '.cwd' "$STATE_FILE")"
TOPIC="$(printf '%s · %s' "$TITLE_FULL" "$CWD_TOPIC")"
curl -sS -X POST https://slack.com/api/conversations.setTopic \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data "$(jq -nc --arg ch "$CHANNEL_ID" --arg t "$TOPIC" '{channel:$ch, topic:$t}')" \
  >/dev/null 2>>"$LOG_FILE"
