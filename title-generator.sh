#!/usr/bin/env bash
# cc-bridge-slack/title-generator.sh
#
# Background helper: given a session_id with a state file containing
# first_prompt + first_reply, ask Bedrock for a short title and rename
# the corresponding Slack channel.
#
# Called from mirror.sh in the background after the first assistant post.
# Exits silently on any error — title rename is best-effort, never blocks
# the user-facing flow.
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

# Token: prefer keychain over env file
if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
  SLACK_BOT_TOKEN="$(security find-generic-password -s cc-bridge-slack -a bot-token -w 2>/dev/null || true)"
fi

RENAMED="$(jq -r '.renamed // false' "$STATE_FILE")"
[[ "$RENAMED" = "true" ]] && exit 0

CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
PROMPT="$(jq -r '.first_prompt // empty' "$STATE_FILE")"
REPLY="$(jq -r '.first_reply // empty' "$STATE_FILE")"
CWD="$(jq -r '.cwd // empty' "$STATE_FILE")"
SURFACE="$(jq -r '.surface // empty' "$STATE_FILE")"
CWD_BASENAME="$(basename "$CWD")"
MIRROR_TAG="${MIRROR_TAG:-cc}"

if [[ -z "$CHANNEL_ID" || -z "$PROMPT" ]]; then
  log "missing channel or prompt"
  exit 0
fi

# === Fast path: piggyback on Claudian's own title ===
# realclaudian plugin writes session metadata to:
#   <vault>/.claudian/sessions/conv-<ts>-<id>.meta.json
# Each meta.json has {sessionId: <cc-sid>, title: "Imperative phrase"}.
# If we're a Claudian-surface session, find the meta.json with our sid
# and reuse its title — saves a Bedrock call AND keeps us perfectly in
# sync with Claudian's sidebar.
TITLE_FULL=""
if [[ "$SURFACE" = "obsidian-claudian" && -d "$CWD/.claudian/sessions" ]]; then
  # Claudian generates titles asynchronously. Wait up to ~30s for it to
  # land — Bedrock fallback only fires when Claudian truly didn't
  # produce one.
  for attempt in $(seq 1 30); do
    # Find the meta file pointing at our sid AND with title generated
    META=$(grep -lF "\"sessionId\": \"$SID\"" "$CWD"/.claudian/sessions/*.meta.json 2>/dev/null | head -1)
    if [[ -n "$META" ]]; then
      STATUS=$(jq -r '.titleGenerationStatus // empty' "$META" 2>/dev/null)
      CANDIDATE=$(jq -r '.title // empty' "$META" 2>/dev/null)
      # Skip placeholder titles like "Start a new conversation" until real one appears
      if [[ "$STATUS" = "success" && -n "$CANDIDATE" && "$CANDIDATE" != "Start a new conversation" ]]; then
        TITLE_FULL="$CANDIDATE"
        log "reused Claudian title: $TITLE_FULL"
        break
      fi
    fi
    sleep 1
  done
fi

# === Bedrock fallback ===
# Reached only for non-Claudian surfaces (terminal CC, iterm, native) or
# when the Claudian title isn't ready/available within the wait window.
if [[ -n "$TITLE_FULL" ]]; then
  TITLE_RAW="$TITLE_FULL"
fi

# Build Bedrock request. Use Haiku 4.5 — fast and cheap.
# Trim inputs (channel-name material doesn't need full prompt).
PROMPT_SHORT="${PROMPT:0:1500}"
REPLY_SHORT="${REPLY:0:1500}"

# Ask for one Claudian-style title sentence. Length 30-60 chars typical.
# We sanitize-and-truncate it ourselves into a kebab slug for channel name,
# and use the original sentence verbatim as the channel topic.
REQUEST_BODY="$(jq -nc \
  --arg p "$PROMPT_SHORT" \
  --arg r "$REPLY_SHORT" \
  '{
    anthropic_version: "bedrock-2023-05-31",
    max_tokens: 60,
    messages: [{
      role: "user",
      content: ("Summarize this Claude Code session in a single short imperative sentence, the way Obsidian Claudian names conversations: title-case-ish, 4-8 words, no period, like \"Consolidate dev/ideas files into one MD\" or \"Design modern homepage for tools portfolio site\". ONLY output that one sentence, no quotes, no explanation.\n\nUser prompt:\n" + $p + "\n\nClaude reply:\n" + $r)
    }]
  }')"

if [[ -z "${TITLE_RAW:-}" ]]; then
  # Write to temp file because aws cli is picky about --body
  REQ_FILE="$(mktemp)"
  RESP_FILE="$(mktemp)"
  printf '%s' "$REQUEST_BODY" >"$REQ_FILE"

  AWS_REGION_VAL="${AWS_REGION:-us-west-2}"
  AWS_PROFILE_VAL="${AWS_PROFILE:-claude-code-DO-NOT-DELETE}"
  MODEL_ID="us.anthropic.claude-haiku-4-5-20251001-v1:0"

  if ! AWS_PROFILE="$AWS_PROFILE_VAL" AWS_REGION="$AWS_REGION_VAL" \
    aws bedrock-runtime invoke-model \
    --model-id "$MODEL_ID" \
    --content-type application/json \
    --accept application/json \
    --body "fileb://$REQ_FILE" \
    "$RESP_FILE" >/dev/null 2>>"$LOG_FILE"; then
    log "bedrock invoke failed (model=$MODEL_ID)"
    rm -f "$REQ_FILE" "$RESP_FILE"
    exit 0
  fi

  TITLE_RAW="$(jq -r '.content[0].text // empty' "$RESP_FILE" 2>/dev/null)"
  rm -f "$REQ_FILE" "$RESP_FILE"
fi

if [[ -z "$TITLE_RAW" ]]; then
  log "empty title from bedrock"
  exit 0
fi

# Strip wrapping quotes/whitespace from model output
TITLE_FULL="$(printf '%s' "$TITLE_RAW" \
  | sed -E 's/^[[:space:]"'"'"']+//; s/[[:space:]"'"'"']+$//')"

if [[ -z "$TITLE_FULL" ]]; then
  log "title empty after sanitize: '$TITLE_RAW'"
  exit 0
fi

# Build channel-safe slug from the full title:
# - lowercase
# - everything non-[a-z0-9] -> hyphen
# - collapse runs of hyphens, trim
# - cut to 70 chars (Slack max 80, keep headroom for collision suffix)
NEW_NAME="$(printf '%s' "$TITLE_FULL" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-70)"

if [[ -z "$NEW_NAME" ]]; then
  log "slug empty after sanitize: '$TITLE_FULL'"
  exit 0
fi

# Try rename, with -2/-3/-4 suffix on name_taken collision
FINAL_NAME=""
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

if [[ -n "$FINAL_NAME" ]]; then
  TMP="$(mktemp)"
  jq --arg n "$FINAL_NAME" --arg t "$TITLE_FULL" \
    '.channel_name=$n | .title=$t | .renamed=true' \
    "$STATE_FILE" >"$TMP" && mv "$TMP" "$STATE_FILE"
  log "renamed to $FINAL_NAME (title='$TITLE_FULL')"

  # Replace topic with the human-readable title + cwd. (init message
  # already has full surface/device/sid metadata; topic stays compact.)
  CWD_TOPIC="$(jq -r '.cwd' "$STATE_FILE")"
  TOPIC="$(printf '%s · %s' "$TITLE_FULL" "$CWD_TOPIC")"
  curl -sS -X POST https://slack.com/api/conversations.setTopic \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$(jq -nc --arg ch "$CHANNEL_ID" --arg t "$TOPIC" '{channel:$ch, topic:$t}')" \
    >/dev/null 2>>"$LOG_FILE"
else
  log "rename failed: $RESP"
fi
