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
CWD_BASENAME="$(basename "$CWD")"
MIRROR_TAG="${MIRROR_TAG:-cc}"

if [[ -z "$CHANNEL_ID" || -z "$PROMPT" ]]; then
  log "missing channel or prompt"
  exit 0
fi

# Build Bedrock request. Use Haiku 3.5 — fast and cheap.
# Trim inputs (channel-name material doesn't need full prompt).
PROMPT_SHORT="${PROMPT:0:1500}"
REPLY_SHORT="${REPLY:0:1500}"

REQUEST_BODY="$(jq -nc \
  --arg p "$PROMPT_SHORT" \
  --arg r "$REPLY_SHORT" \
  '{
    anthropic_version: "bedrock-2023-05-31",
    max_tokens: 30,
    messages: [{
      role: "user",
      content: ("Generate a 2-4 word title in lowercase kebab-case (a-z, 0-9, hyphens only) summarizing this Claude Code session. Be concise — fewer words is better. ONLY output the slug, no quotes, no explanation.\n\nUser prompt:\n" + $p + "\n\nClaude reply:\n" + $r)
    }]
  }')"

# Write to temp file because aws cli is picky about --body
REQ_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"
printf '%s' "$REQUEST_BODY" >"$REQ_FILE"

# Use the same AWS profile CC uses (from main settings.json env block)
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

if [[ -z "$TITLE_RAW" ]]; then
  log "empty title from bedrock"
  exit 0
fi

# Sanitize: lowercase, replace spaces/underscores with hyphens, strip non-allowed
TITLE_SLUG="$(printf '%s' "$TITLE_RAW" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '-' \
  | tr -cd 'a-z0-9-' \
  | sed -E 's/^-+//; s/-+$//; s/-+/-/g' \
  | cut -c1-30)"

if [[ -z "$TITLE_SLUG" ]]; then
  log "title slug empty after sanitize: '$TITLE_RAW'"
  exit 0
fi

# Channel name is just the title slug — no prefix. (Bedrock is asked for
# 3-6 words; we cap at 50 chars to leave room for collision -2/-3 suffix.)
NEW_NAME="$(printf '%s' "$TITLE_SLUG" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cd 'a-z0-9-' \
  | cut -c1-50)"

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
  jq --arg n "$FINAL_NAME" '.channel_name=$n | .renamed=true' "$STATE_FILE" >"$TMP" && mv "$TMP" "$STATE_FILE"
  log "renamed to $FINAL_NAME"
else
  log "rename failed: $RESP"
fi
