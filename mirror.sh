#!/usr/bin/env bash
# cc-bridge-slack/mirror.sh
#
# Claude Code hook handler. Mirrors CC session events to a per-session
# private Slack channel in Bear's sandbox workspace.
#
# Wired into Claude Code via UserPromptSubmit, Stop, SessionEnd hooks
# (see ~/.claude/settings.json). Runs in the same shell context as the CC
# session — must be fast, must never abort CC, must never leak secrets.
#
# Architecture (Phase 1.5 — channel-per-session):
#   - Each CC session_id maps to one private Slack channel
#   - Mapping persisted at ~/.claude/tools/cc-bridge-state/<sid>.json
#   - First UserPromptSubmit creates channel cc-<cwd>-<sid8> (placeholder)
#   - Title-generation Stop fire renames channel to include CC's title
#   - SessionEnd archives channel
#   - User msgs post as Bear (with gravatar); assistant msgs post as
#     "Claude Code" (with CC icon)
#
# Usage:
#   cat payload.json | ./mirror.sh user        # UserPromptSubmit
#   cat payload.json | ./mirror.sh assistant   # Stop
#   cat payload.json | ./mirror.sh end         # SessionEnd
#
# Env (loaded from $ENV_FILE if present, default ~/.claude/tools/slack-bridge.env):
#   SLACK_BOT_TOKEN        xoxb-...
#   SLACK_USER_ID          U... (Bear's user id in sandbox)
#   BEAR_DISPLAY_NAME      "Bear" (override Slack username for user posts)
#   BEAR_ICON_URL          https://... (gravatar / Slack avatar URL)
#   CLAUDE_DISPLAY_NAME    "Claude Code"
#   CLAUDE_ICON_URL        https://... (CC logo)
#   MIRROR_TAG             prefix for placeholder channel names; default "cc"
#   MIRROR_DRY_RUN         1 = log only, no API call

set -u

ROLE="${1:-unknown}"
ENV_FILE="${SLACK_BRIDGE_ENV:-$HOME/.claude/tools/slack-bridge.env}"
LOG_FILE="${MIRROR_LOG:-/tmp/cc-mirror-test.log}"
STATE_DIR="${MIRROR_STATE_DIR:-$HOME/.claude/tools/cc-bridge-state}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"; }

# --- load config -------------------------------------------------------------
_inline_dry="${MIRROR_DRY_RUN:-}"
_inline_tag="${MIRROR_TAG:-}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi
[[ -n "$_inline_dry" ]] && MIRROR_DRY_RUN="$_inline_dry"
[[ -n "$_inline_tag" ]] && MIRROR_TAG="$_inline_tag"
MIRROR_TAG="${MIRROR_TAG:-cc}"
MIRROR_DRY_RUN="${MIRROR_DRY_RUN:-0}"
BEAR_DISPLAY_NAME="${BEAR_DISPLAY_NAME:-Bear}"
BEAR_ICON_URL="${BEAR_ICON_URL:-}"
CLAUDE_DISPLAY_NAME="${CLAUDE_DISPLAY_NAME:-Claude Code}"
CLAUDE_ICON_URL="${CLAUDE_ICON_URL:-https://www.anthropic.com/favicon.ico}"

# Bot token: prefer macOS Keychain (so secret never sits in plaintext),
# fall back to env var from the .env file. Keychain item must be created via
# install.sh: `security add-generic-password -U -A -s cc-bridge-slack -a bot-token -w <token>`.
if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
  SLACK_BOT_TOKEN="$(security find-generic-password -s cc-bridge-slack -a bot-token -w 2>/dev/null || true)"
fi
export SLACK_BOT_TOKEN

mkdir -p "$STATE_DIR" 2>/dev/null

# --- read hook payload from stdin -------------------------------------------
PAYLOAD="$(cat)"

if [[ "${MIRROR_DUMP:-0}" = "1" ]]; then
  DIAG_DIR=/tmp/cc-mirror-payloads
  mkdir -p "$DIAG_DIR" 2>/dev/null
  printf '%s' "$PAYLOAD" >"$DIAG_DIR/${ROLE}-$(date +%s%N).json"
fi

# --- common payload fields --------------------------------------------------
SID="$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)"
SESSION_CWD="$(jq -r '.cwd // empty' <<<"$PAYLOAD" 2>/dev/null)"
[[ -z "$SESSION_CWD" ]] && SESSION_CWD="$(pwd)"
CWD_BASENAME="$(basename "$SESSION_CWD")"
SID8="${SID:0:8}"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$PAYLOAD" 2>/dev/null)"

slug() {
  # Slack channel name: lowercase, [a-z0-9-_], <=80 chars
  printf '%s' "$1" \
    | tr '[:upper:] ' '[:lower:]-' \
    | tr -cd 'a-z0-9-_' \
    | cut -c1-60
}

# Placeholder name while waiting for Bedrock to generate a real title.
# Use the short sid8 only — final name will be a clean slug from title-generator.
CHANNEL_PLACEHOLDER="$(slug "session-${SID8}")"

# --- extract content --------------------------------------------------------
extract() {
  local role="$1" payload="$2"
  case "$role" in
    user)
      jq -r '.prompt // .user_prompt // .message // empty' <<<"$payload" 2>/dev/null
      ;;
    assistant)
      jq -r '.last_assistant_message // empty' <<<"$payload" 2>/dev/null
      ;;
    end)
      jq -r '.reason // "ended"' <<<"$payload" 2>/dev/null
      ;;
    *)
      jq -r '.' <<<"$payload" 2>/dev/null
      ;;
  esac
}

# CC-internal noise that should not reach Slack as a user prompt.
# (Title generation comes through UserPromptSubmit too.)
is_user_noise() {
  local content="$1"
  [[ "$content" == *"Generate a title for this conversation"* ]] && return 0
  [[ "$content" == *"Your task is to create a"* && "$content" == *"summary"* ]] && return 0
  return 1
}

# CC's own internal title-gen Stop (short, no-newline reply right after a
# real Stop) — we ignore these entirely now that we generate titles
# ourselves via Bedrock.
is_cc_internal_title() {
  local text="$1"
  local len=${#text}
  (( len > 0 && len < 60 )) && [[ "$text" != *$'\n'* ]] && return 0
  return 1
}

CONTENT="$(extract "$ROLE" "$PAYLOAD")"

# --- Slack API helpers ------------------------------------------------------
slack_api() {
  local method="$1" body="$2"
  curl -sS -X POST "https://slack.com/api/${method}" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$body" 2>>"$LOG_FILE"
}

# Resolve / create channel for current session. Echoes channel_id, or empty.
ensure_channel() {
  local sid="$1" placeholder="$2" cwd="$3" transcript="${4:-}"
  local state_file="$STATE_DIR/$sid.json"

  if [[ -f "$state_file" ]]; then
    jq -r '.channel_id // empty' "$state_file" 2>/dev/null
    return
  fi

  # Create private channel. Retry with -2, -3 suffix on name_taken.
  local create_body create_resp ch_id err try_name
  for suffix in '' '-2' '-3' '-4'; do
    try_name="${placeholder}${suffix}"
    create_body="$(jq -nc --arg name "$try_name" '{name:$name, is_private:true}')"
    create_resp="$(slack_api conversations.create "$create_body")"
    ch_id="$(jq -r '.channel.id // empty' <<<"$create_resp" 2>/dev/null)"
    [[ -n "$ch_id" ]] && break
    err="$(jq -r '.error // ""' <<<"$create_resp")"
    [[ "$err" != "name_taken" ]] && break
  done

  if [[ -z "$ch_id" ]]; then
    log "conversations.create failed name=$placeholder err=$err"
    return
  fi

  # Detect surface (best-effort)
  local surface
  surface="$(SURFACE_SCRIPT="$(dirname "$0")/detect-surface.sh"; \
             [[ -x "$SURFACE_SCRIPT" ]] && "$SURFACE_SCRIPT" "$transcript" || echo unknown)"
  surface="${surface:-unknown}"

  # Set topic with full sid + cwd + surface
  local topic
  topic="$(printf 'session: %s · surface: %s · cwd: %s' "$sid" "$surface" "$cwd")"
  slack_api conversations.setTopic \
    "$(jq -nc --arg ch "$ch_id" --arg t "$topic" '{channel:$ch, topic:$t}')" >/dev/null

  # Invite Bear
  slack_api conversations.invite \
    "$(jq -nc --arg ch "$ch_id" --arg u "$SLACK_USER_ID" '{channel:$ch, users:$u}')" >/dev/null

  # Post init message (multi-line, formatted)
  local hostname now sid8
  hostname="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
  now="$(date '+%H:%M (%Y-%m-%d)')"
  sid8="${sid:0:8}"
  local init_text
  init_text="$(printf '*Session start*\n• Started: %s\n• Surface: \`%s\`\n• Device: \`%s\`\n• Cwd: \`%s\`\n• Session: \`%s\`' \
    "$now" "$surface" "$hostname" "$cwd" "$sid8")"
  post_to_channel "$ch_id" "$init_text" "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" >/dev/null

  # Persist mapping (record surface for future status queries)
  jq -nc \
    --arg sid "$sid" --arg ch "$ch_id" --arg name "$placeholder" \
    --arg cwd "$cwd" --arg surface "$surface" --arg device "$hostname" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{session_id:$sid, channel_id:$ch, channel_name:$name, cwd:$cwd, surface:$surface, device:$device, created:$created, renamed:false}' \
    >"$state_file"

  log "created channel $placeholder ($ch_id) sid=$sid surface=$surface"
  printf '%s' "$ch_id"
}

# Convert GitHub-flavored markdown to Slack's mrkdwn syntax.
# Code blocks (triple-backtick and inline backtick) are protected verbatim
# so things like `**foo**` stay literal inside code.
# Calls Python via -c with the input on stdin via process-sub redirection
# so it composes cleanly inside other pipelines.
gfm_to_mrkdwn() {
  python3 -c '
import re, sys
text = sys.stdin.read()
blocks = []
def stash(m):
    blocks.append(m.group(0))
    return f"\x00{len(blocks)-1}\x00"
text = re.sub(r"```[\s\S]*?```", stash, text)
text = re.sub(r"`[^`\n]+`", stash, text)
text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r"<\2|\1>", text)
text = re.sub(r"(?m)^#{1,6}\s+(.+?)\s*$", r"*\1*", text)
text = re.sub(r"\*\*([^*\n]+?)\*\*", r"*\1*", text)
text = re.sub(r"~~([^~\n]+?)~~", r"~\1~", text)
def restore(m): return blocks[int(m.group(1))]
text = re.sub(r"\x00(\d+)\x00", restore, text)
sys.stdout.write(text)
'
}

post_to_channel() {
  local channel="$1" text="$2" username="$3" icon_url="$4"
  local body
  body="$(jq -nc \
    --arg ch "$channel" \
    --arg t "$text" \
    --arg u "$username" \
    --arg i "$icon_url" \
    '{channel:$ch, text:$t, mrkdwn:true, username:$u} + (if $i != "" then {icon_url:$i} else {} end)')"
  local resp ok
  resp="$(slack_api chat.postMessage "$body")"
  ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null)"
  if [[ "$ok" != "true" ]]; then
    log "ERROR chat.postMessage role=$ROLE: $resp"
    return 1
  fi
  return 0
}

rename_channel() {
  local channel="$1" new_name="$2"
  local resp
  resp="$(slack_api conversations.rename \
    "$(jq -nc --arg ch "$channel" --arg n "$new_name" '{channel:$ch, name:$n}')")"
  local ok
  ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null)"
  if [[ "$ok" = "true" ]]; then
    log "renamed channel $channel -> $new_name"
    return 0
  fi
  log "rename failed channel=$channel new_name=$new_name: $resp"
  return 1
}

archive_channel() {
  local channel="$1"
  local resp
  resp="$(slack_api conversations.archive \
    "$(jq -nc --arg ch "$channel" '{channel:$ch}')")"
  local ok
  ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null)"
  if [[ "$ok" = "true" ]]; then
    log "archived channel $channel"
  else
    log "archive failed channel=$channel: $resp"
  fi
}

# --- main flow --------------------------------------------------------------

# Filter user-side noise (title generation prompts etc.)
if [[ "$ROLE" = "user" ]] && is_user_noise "$CONTENT"; then
  log "skip user (cc-internal noise) sid=$SID8"
  exit 0
fi

# Empty content: nothing to do for user/assistant; SessionEnd we still process
if [[ -z "$CONTENT" && "$ROLE" != "end" ]]; then
  log "skip role=$ROLE (empty content) sid=$SID8"
  exit 0
fi

# Convert assistant content from GitHub-flavored markdown to Slack mrkdwn.
# User prompts pass through unchanged (people don't typically type ** in chat).
if [[ "$ROLE" = "assistant" ]]; then
  CONTENT="$(printf '%s' "$CONTENT" | gfm_to_mrkdwn)"
fi

# Truncate to Slack-friendly size
MAX=3500
if (( ${#CONTENT} > MAX )); then
  CONTENT="${CONTENT:0:$MAX}"$'\n…[truncated]'
fi

# Dry-run: just log and bail
if [[ "$MIRROR_DRY_RUN" = "1" ]]; then
  log "DRY_RUN role=$ROLE sid=$SID8 placeholder=$CHANNEL_PLACEHOLDER bytes=${#CONTENT}"
  log "----- preview -----"
  printf '%s\n' "$CONTENT" | head -10 >>"$LOG_FILE"
  log "-------------------"
  exit 0
fi

if [[ -z "${SLACK_BOT_TOKEN:-}" || -z "${SLACK_USER_ID:-}" ]]; then
  log "ERROR missing SLACK_BOT_TOKEN or SLACK_USER_ID"
  exit 0
fi

if [[ -z "$SID" ]]; then
  log "ERROR no session_id in payload role=$ROLE"
  exit 0
fi

STATE_FILE="$STATE_DIR/$SID.json"

case "$ROLE" in
  user)
    CHANNEL_ID="$(ensure_channel "$SID" "$CHANNEL_PLACEHOLDER" "$SESSION_CWD" "$TRANSCRIPT_PATH")"
    [[ -z "$CHANNEL_ID" ]] && exit 0
    post_to_channel "$CHANNEL_ID" "$CONTENT" "$BEAR_DISPLAY_NAME" "$BEAR_ICON_URL" \
      && log "ok role=user channel=$CHANNEL_ID sid=$SID8 bytes=${#CONTENT}"

    # Save first prompt for later title generation
    if [[ -f "$STATE_FILE" ]]; then
      HAS_FIRST="$(jq -r 'has("first_prompt")' "$STATE_FILE" 2>/dev/null)"
      if [[ "$HAS_FIRST" != "true" ]]; then
        TMP="$(mktemp)"
        jq --arg p "$CONTENT" '. + {first_prompt:$p}' "$STATE_FILE" >"$TMP" && mv "$TMP" "$STATE_FILE"
      fi
    fi
    ;;

  assistant)
    # If no state file exists, the user prompt was filtered as noise (CC
    # internal sub-session: title generation, todo regen, summarization).
    # Skip — don't create a channel for sub-sessions.
    if [[ ! -f "$STATE_FILE" ]]; then
      log "skip assistant (no state — sub-session) sid=$SID8"
      exit 0
    fi
    CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
    if [[ -z "$CHANNEL_ID" ]]; then
      log "skip assistant (state file but no channel_id) sid=$SID8"
      exit 0
    fi

    # First reply: SYNCHRONOUSLY rename channel before posting, so the
    # message lands in an already-properly-named channel.
    # Subsequent replies skip this entire block (no latency).
    if [[ -f "$STATE_FILE" ]]; then
      RENAMED="$(jq -r '.renamed // false' "$STATE_FILE")"
      HAS_FIRST_REPLY="$(jq -r 'has("first_reply")' "$STATE_FILE")"
      if [[ "$RENAMED" != "true" && "$HAS_FIRST_REPLY" != "true" ]]; then
        TMP="$(mktemp)"
        jq --arg r "$CONTENT" '. + {first_reply:$r}' "$STATE_FILE" >"$TMP" && mv "$TMP" "$STATE_FILE"
        TITLE_GEN="$(dirname "$0")/title-generator.sh"
        if [[ -x "$TITLE_GEN" ]]; then
          # Synchronous: title-generator returns when rename completes (or fails).
          # Adds 1-3s to the FIRST reply only.
          "$TITLE_GEN" "$SID" >/dev/null 2>&1
          log "title-gen done sid=$SID8"
        fi
      fi
    fi

    post_to_channel "$CHANNEL_ID" "$CONTENT" "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" \
      && log "ok role=assistant channel=$CHANNEL_ID sid=$SID8 bytes=${#CONTENT}"
    ;;

  end)
    # No state means we never created a channel for this session — nothing
    # to archive. Common case: cc-internal sub-session.
    if [[ ! -f "$STATE_FILE" ]]; then
      log "skip end (no state — sub-session) sid=$SID8"
      exit 0
    fi
    CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
    if [[ -n "$CHANNEL_ID" ]]; then
      # Post a final marker, then archive
      post_to_channel "$CHANNEL_ID" "_session ended ($CONTENT)_" \
        "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" >/dev/null
      archive_channel "$CHANNEL_ID"
    fi
    ;;

  *)
    log "skip unknown role=$ROLE"
    ;;
esac

exit 0
