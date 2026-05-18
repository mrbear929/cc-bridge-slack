#!/usr/bin/env bash
# cc-bridge-slack/mirror.sh
#
# Claude Code hook handler. Mirrors CC session events to a per-session
# private Slack channel in the user's Slack workspace.
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
#   - User msgs post as the user-identity override (avatar from env); assistant msgs post as
#     "Claude Code" (with CC icon)
#
# Usage:
#   cat payload.json | ./mirror.sh user        # UserPromptSubmit
#   cat payload.json | ./mirror.sh assistant   # Stop
#   cat payload.json | ./mirror.sh end         # SessionEnd
#
# Env (loaded from $ENV_FILE if present, default ~/.claude/tools/slack-bridge.env):
#   SLACK_BOT_TOKEN        xoxb-...
#   SLACK_USER_ID          U... (the user's Slack member id)
#   USER_DISPLAY_NAME      "<name>" (override Slack username for user posts)
#   USER_ICON_URL          https://... (gravatar / Slack avatar URL)
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
USER_DISPLAY_NAME="${USER_DISPLAY_NAME:-You}"
USER_ICON_URL="${USER_ICON_URL:-}"
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
chmod 700 "$STATE_DIR" 2>/dev/null

# Per-sid mutex helpers. macOS lacks `flock`, so we use `mkdir` which is
# atomic on POSIX filesystems. The lock dir is removed in a trap.
state_lock() {
  local sid="$1" tries=0
  local lockdir="$STATE_DIR/.lock-$sid"
  while ! mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    # Stale lock cleanup: lock older than 10s gets blown away.
    if [[ -d "$lockdir" ]]; then
      local age
      age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || echo 0) ))
      if (( age > 10 )); then
        rm -rf "$lockdir" 2>/dev/null
        continue
      fi
    fi
    (( tries > 50 )) && return 1   # ~5s give-up
    sleep 0.1
  done
  return 0
}
state_unlock() {
  rm -rf "$STATE_DIR/.lock-$1" 2>/dev/null
}

# safe_state_update <sid> <jq-filter-args...>
# Atomically reads STATE_FILE, applies jq filter, writes back. Uses
# mkdir-mutex to coordinate with the daemon and other concurrent
# mirror.sh invocations for the same sid.
safe_state_update() {
  local sid="$1"; shift
  local f="$STATE_DIR/$sid.json"
  [[ -f "$f" ]] || return 1
  if ! state_lock "$sid"; then
    log "WARN could not acquire state lock sid=${sid:0:8} — skipping update"
    return 1
  fi
  local tmp; tmp="$(mktemp)"
  if jq "$@" "$f" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  state_unlock "$sid"
}

# Daemon-controlled kill switch: presence of 'disabled' flag = paused.
# Only blocks NEW sessions from being created. Already-active sessions
# (with state files) keep mirroring through the rest of their lifetime.
if [[ -f "$STATE_DIR/disabled" ]]; then
  # Read sid early so we can check whether this session is already tracked.
  _sid_check="$(jq -r '.session_id // empty' 2>/dev/null < /dev/stdin)"
  # Re-buffer stdin (we'll re-read below). Actually too late: stdin already
  # consumed. Better approach: only block 'user' role for sessions without
  # an existing state file. Use a peek: capture payload first, check after.
  : # fall through; real check happens after PAYLOAD is captured
fi

# --- read hook payload from stdin -------------------------------------------
PAYLOAD="$(cat)"

# Apply daemon-controlled kill switch (correct version, after PAYLOAD captured)
if [[ -f "$STATE_DIR/disabled" ]]; then
  _sid="$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)"
  # Only suppress new sessions: if state file exists, this session was
  # already accepted before pause — let it finish normally.
  if [[ -n "$_sid" && ! -f "$STATE_DIR/$_sid.json" ]]; then
    log "skip role=$ROLE (cc-bridge disabled, sid=${_sid:0:8})"
    exit 0
  fi
fi

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
    question|answer)
      # AskUserQuestion: return the entire tool_input/tool_response object as JSON
      jq -c '.' <<<"$payload" 2>/dev/null
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
    local existing_ch
    existing_ch="$(jq -r '.channel_id // empty' "$state_file" 2>/dev/null)"
    # If user is reopening an old session, the channel may have been
    # archived when the previous SessionEnd fired. Unarchive it now so
    # the upcoming post lands. Also clear the archived flag in state.
    if [[ "$(jq -r '.archived // false' "$state_file" 2>/dev/null)" = "true" ]]; then
      log "reopened session sid=${sid:0:8} — unarchiving channel $existing_ch"
      slack_api conversations.unarchive \
        "$(jq -nc --arg ch "$existing_ch" '{channel:$ch}')" >/dev/null
      safe_state_update "$sid" 'del(.archived) | del(.archived_at) | del(.archived_by)'
    fi
    printf '%s' "$existing_ch"
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

  # Invite the user
  slack_api conversations.invite \
    "$(jq -nc --arg ch "$ch_id" --arg u "$SLACK_USER_ID" '{channel:$ch, users:$u}')" >/dev/null

  # Post init message (multi-line, formatted)
  local hostname now transcript_dir
  hostname="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
  now="$(date '+%H:%M (%Y-%m-%d)')"
  transcript_dir="$(dirname "$transcript")"
  local init_text
  init_text="$(printf '*Session start*\n• Started: %s\n• Surface: \`%s\`\n• Device: \`%s\`\n• Cwd: \`%s\`\n• Session: \`%s\`\n• Transcript: \`%s\`' \
    "$now" "$surface" "$hostname" "$cwd" "$sid" "$transcript")"
  post_to_channel "$ch_id" "$init_text" "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" >/dev/null

  # Persist mapping (record surface for future status queries)
  jq -nc \
    --arg sid "$sid" --arg ch "$ch_id" --arg name "$placeholder" \
    --arg cwd "$cwd" --arg surface "$surface" --arg device "$hostname" \
    --arg transcript "$transcript" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{session_id:$sid, channel_id:$ch, channel_name:$name, cwd:$cwd, surface:$surface, device:$device, transcript_path:$transcript, created:$created, renamed:false}' \
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

# Upload images from the user message MATCHING the given prompt text.
# Synchronous; retries internally until the transcript catches up.
# Args: $1 = transcript_path, $2 = channel_id, $3 = prompt text (anchor)
# Cap: 5 MB per image. Skips silently on missing transcript / decode errors.
upload_user_images() {
  local transcript="$1" channel="$2" prompt_text="$3"
  [[ -z "$transcript" ]] && return 0
  [[ -z "$prompt_text" ]] && return 0

  local extract_dir
  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-bridge-imgs.XXXXXX")" || return 0

  # Retry up to ~90 seconds for (a) the transcript file to appear AND (b)
  # the user message matching this prompt to land in it with image content.
  # Claudian buffers transcript writes; can take 30+ seconds for first turn.
  # We're called in the background so latency here doesn't matter much.
  local found=0
  for attempt in $(seq 1 60); do
    if [[ ! -f "$transcript" ]]; then
      sleep 1.5
      continue
    fi
    python3 - "$transcript" "$extract_dir" "$prompt_text" >/dev/null 2>&1 <<'PY'
import json, sys, base64, os
transcript_path, out_dir, anchor = sys.argv[1], sys.argv[2], sys.argv[3]

# Find the user message whose .message.content includes a text block whose
# text starts with the anchor (the .prompt the hook saw). Then extract any
# image content from that same message.
target = None
def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                parts.append(c.get("text", ""))
        return "\n".join(parts)
    return ""

with open(transcript_path) as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") != "user":
            continue
        msg = d.get("message", {}) if isinstance(d.get("message"), dict) else {}
        content = msg.get("content")
        # Match if the anchor is a substring of the joined text content
        # (Claudian sometimes wraps prompts with editor_selection tags etc.)
        if anchor and anchor[:80] in text_of(content):
            target = content
            # don't break — keep last match (most recent identical prompt wins)

if not target:
    # No matching user message yet — signal "retry"
    sys.exit(2)

# We found the right user message. Extract images (or none).
if not isinstance(target, list):
    sys.exit(0)  # no images, done — no retry needed

found_any = False
idx = 0
for c in target:
    if not isinstance(c, dict) or c.get("type") != "image":
        continue
    src = c.get("source", {})
    if src.get("type") != "base64":
        continue
    media = src.get("media_type", "image/png")
    ext = media.split("/")[-1] or "png"
    data_b64 = src.get("data", "")
    try:
        raw = base64.b64decode(data_b64)
    except Exception:
        continue
    if len(raw) > 5 * 1024 * 1024:
        continue
    idx += 1
    found_any = True
    path = os.path.join(out_dir, f"image-{idx}.{ext}")
    with open(path, "wb") as out:
        out.write(raw)
sys.exit(0 if found_any or idx == 0 else 0)
PY
    rc=$?
    if [[ $rc -eq 0 ]]; then
      found=1
      break
    fi
    # rc==2 means transcript hasn't caught up — sleep and retry
    sleep 1.5
  done

  if [[ $found -ne 1 ]]; then
    log "image upload: gave up waiting for transcript anchor (sid=$SID8)"
    rm -rf "$extract_dir"
    return 0
  fi

  for img_path in "$extract_dir"/*; do
    [[ ! -f "$img_path" ]] && continue

    local fname size
    fname="$(basename "$img_path")"
    size=$(stat -f%z "$img_path" 2>/dev/null || stat -c%s "$img_path")

    # Step 1: get upload URL
    local upload_resp upload_url file_id
    upload_resp="$(curl -sS -G "https://slack.com/api/files.getUploadURLExternal" \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      --data-urlencode "filename=$fname" \
      --data-urlencode "length=$size" 2>>"$LOG_FILE")"
    upload_url="$(jq -r '.upload_url // empty' <<<"$upload_resp" 2>/dev/null)"
    file_id="$(jq -r '.file_id // empty' <<<"$upload_resp" 2>/dev/null)"
    if [[ -z "$upload_url" || -z "$file_id" ]]; then
      log "image upload step1 failed: $upload_resp"
      continue
    fi

    # Step 2: POST file bytes
    if ! curl -sS --data-binary "@$img_path" "$upload_url" >/dev/null 2>>"$LOG_FILE"; then
      log "image upload step2 failed for $fname"
      continue
    fi

    # Step 3: complete WITHOUT sharing to channel (no channel_id), so Slack
    # finalizes the file but doesn't post the system "bot uploaded a file"
    # message. We share via chat.postMessage with the user-identity in step 4.
    local complete_body complete_resp ok permalink
    complete_body="$(jq -nc --arg fid "$file_id" --arg title "$fname" \
      '{files:[{id:$fid, title:$title}]}')"
    complete_resp="$(slack_api files.completeUploadExternal "$complete_body")"
    ok="$(jq -r '.ok' <<<"$complete_resp" 2>/dev/null)"
    if [[ "$ok" != "true" ]]; then
      log "image upload step3 failed: $complete_resp"
      continue
    fi
    permalink="$(jq -r '.files[0].permalink // empty' <<<"$complete_resp" 2>/dev/null)"
    if [[ -z "$permalink" ]]; then
      log "image upload step3 ok but no permalink: $complete_resp"
      continue
    fi

    # Step 4: post as user with the permalink — Slack unfurls it inline.
    # Use <url| > with empty visible text so the link itself is hidden
    # but Slack still unfurls it as the image preview underneath.
    local post_body post_resp post_ok
    local hidden_link
    hidden_link="<${permalink}| >"
    post_body="$(jq -nc \
      --arg ch "$channel" \
      --arg t "$hidden_link" \
      --arg u "$USER_DISPLAY_NAME" \
      --arg i "$USER_ICON_URL" \
      '{channel:$ch, text:$t, mrkdwn:true, username:$u, unfurl_links:true, unfurl_media:true}
       + (if $i != "" then {icon_url:$i} else {} end)')"
    post_resp="$(slack_api chat.postMessage "$post_body")"
    post_ok="$(jq -r '.ok' <<<"$post_resp" 2>/dev/null)"
    if [[ "$post_ok" = "true" ]]; then
      log "image uploaded+posted $fname ($size bytes) as user in $channel"
    else
      log "image upload step4 (post as user) failed: $post_resp"
    fi
  done

  rm -rf "$extract_dir"
  return 0
}

# Posts a message and exports POSTED_TS (caller can read after this returns).
# Empty POSTED_TS means the post failed.
POSTED_TS=""
post_to_channel() {
  local channel="$1" text="$2" username="$3" icon_url="$4"
  POSTED_TS=""
  local body
  body="$(jq -nc \
    --arg ch "$channel" \
    --arg t "$text" \
    --arg u "$username" \
    --arg i "$icon_url" \
    '{channel:$ch, text:$t, mrkdwn:true, username:$u} + (if $i != "" then {icon_url:$i} else {} end)')"
  local resp ok err
  resp="$(slack_api chat.postMessage "$body")"
  ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null)"
  if [[ "$ok" = "true" ]]; then
    POSTED_TS="$(jq -r '.ts // empty' <<<"$resp" 2>/dev/null)"
    return 0
  fi

  err="$(jq -r '.error // ""' <<<"$resp")"
  # Auto-recover from accidental archive (e.g. SessionEnd fired prematurely
  # for a session that's actually still alive — Claudian's lifecycle is
  # not always a clean end-of-life). Unarchive + retry once. Also clear
  # archived flag in state so daemon's `active` query reflects reality.
  if [[ "$err" = "is_archived" ]]; then
    log "channel $channel was archived — unarchiving and retrying"
    slack_api conversations.unarchive \
      "$(jq -nc --arg ch "$channel" '{channel:$ch}')" >/dev/null
    # Clear archived flag from any state file pointing at this channel
    for sf in "$STATE_DIR"/*.json; do
      [[ -f "$sf" ]] || continue
      if [[ "$(jq -r '.channel_id // empty' "$sf")" = "$channel" ]]; then
        TMP="$(mktemp)"
        jq 'del(.archived) | del(.archived_at)' "$sf" >"$TMP" && mv "$TMP" "$sf"
      fi
    done
    # Retry the post
    resp="$(slack_api chat.postMessage "$body")"
    ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null)"
    if [[ "$ok" = "true" ]]; then
      POSTED_TS="$(jq -r '.ts // empty' <<<"$resp" 2>/dev/null)"
      return 0
    fi
  fi

  log "ERROR chat.postMessage role=$ROLE: $resp"
  return 1
}

# Add a reaction to a message. Best-effort, errors swallowed.
add_reaction() {
  local channel="$1" ts="$2" name="$3"
  [[ -z "$ts" ]] && return 0
  slack_api reactions.add \
    "$(jq -nc --arg ch "$channel" --arg ts "$ts" --arg n "$name" \
       '{channel:$ch, timestamp:$ts, name:$n}')" >/dev/null 2>&1 || true
}

remove_reaction() {
  local channel="$1" ts="$2" name="$3"
  [[ -z "$ts" ]] && return 0
  slack_api reactions.remove \
    "$(jq -nc --arg ch "$channel" --arg ts "$ts" --arg n "$name" \
       '{channel:$ch, timestamp:$ts, name:$n}')" >/dev/null 2>&1 || true
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

    # Mark session busy: daemon uses this to queue inbound Slack messages
    # rather than racing the live cc process. Cleared on Stop.
    if [[ -f "$STATE_FILE" ]]; then
      safe_state_update "$SID" '. + {busy: true}'
    fi

    # When daemon's reply-routing spawned this turn, the user's prompt is
    # already in Slack as their xzixuan message — skip mirror to avoid a
    # duplicate user post.
    # Daemon's reply-routing creates a marker file before spawning
    # `claude -p --resume`. mirror.sh inside that subprocess sees the
    # marker and skips: posting the mirrored user (would duplicate the
    # original Slack message) and archiving on SessionEnd (resume's
    # SessionEnd is not a real exit). Env var was tried first but CC
    # strips env when spawning hooks — file marker survives.
    FROM_SLACK_MARKER="$STATE_DIR/from-slack/$SID"
    if [[ -f "$FROM_SLACK_MARKER" ]] || [[ "${CC_BRIDGE_FROM_SLACK:-0}" = "1" ]]; then
      log "skip user mirror (from-slack inject) sid=$SID8"
    else
      if post_to_channel "$CHANNEL_ID" "$CONTENT" "$USER_DISPLAY_NAME" "$USER_ICON_URL"; then
        log "ok role=user channel=$CHANNEL_ID sid=$SID8 bytes=${#CONTENT}"
        # Mark this prompt as in-progress with :hourglass:. The Stop hook
        # below will swap it to :white_check_mark: when CC's reply lands.
        # Mirrors the daemon's reply-routing UX: phone-side viewer can
        # tell at a glance whether CC is currently chewing on a turn.
        if [[ -n "$POSTED_TS" ]]; then
          add_reaction "$CHANNEL_ID" "$POSTED_TS" "hourglass_flowing_sand"
          safe_state_update "$SID" --arg ts "$POSTED_TS" '. + {pending_user_ts:$ts}'
        fi
      fi
    fi

    # Background image upload: Claudian buffers the transcript and flushes
    # only after the first round-trip completes — sometimes 30+ seconds.
    # Sync wait would block the hook past CC's 60s timeout AND delay the
    # prompt appearing in Slack. So fork a detached worker that retries up
    # to ~90 seconds. The image lands in Slack a few seconds (or up to a
    # minute) after the prompt — close enough that they read together.
    if [[ -n "$TRANSCRIPT_PATH" ]]; then
      ( upload_user_images "$TRANSCRIPT_PATH" "$CHANNEL_ID" "$CONTENT" >/dev/null 2>&1 & disown ) 2>/dev/null
    fi

    # Save first prompt for later title generation
    if [[ -f "$STATE_FILE" ]]; then
      HAS_FIRST="$(jq -r 'has("first_prompt")' "$STATE_FILE" 2>/dev/null)"
      if [[ "$HAS_FIRST" != "true" ]]; then
        safe_state_update "$SID" --arg p "$CONTENT" '. + {first_prompt:$p}'
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

    # First reply: kick off title generation as a detached background
    # job. Used to be synchronous (1-3s before reply landed) — but
    # Claudian's own title can lag 5-30s, and we want to reuse it
    # rather than burn a Bedrock call. Detaching lets the reply post
    # immediately; title-generator.sh patiently waits for Claudian's
    # meta.json and renames the channel when ready.
    if [[ -f "$STATE_FILE" ]]; then
      RENAMED="$(jq -r '.renamed // false' "$STATE_FILE")"
      HAS_FIRST_REPLY="$(jq -r 'has("first_reply")' "$STATE_FILE")"
      if [[ "$RENAMED" != "true" && "$HAS_FIRST_REPLY" != "true" ]]; then
        safe_state_update "$SID" --arg r "$CONTENT" '. + {first_reply:$r}'
        TITLE_GEN="$(dirname "$0")/title-generator.sh"
        if [[ -x "$TITLE_GEN" ]]; then
          ( "$TITLE_GEN" "$SID" >/dev/null 2>&1 & disown ) 2>/dev/null
          log "title-gen queued (background) sid=$SID8"
        fi
      fi
    fi

    post_to_channel "$CHANNEL_ID" "$CONTENT" "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" \
      && log "ok role=assistant channel=$CHANNEL_ID sid=$SID8 bytes=${#CONTENT}"

    # Swap any pending :hourglass: on the most recent user prompt to
    # :white_check_mark: now that CC has finished this turn. Daemon-driven
    # injects already manage their own reactions on the user's Slack-side
    # message; this branch handles the local-CC case.
    PENDING_TS="$(jq -r '.pending_user_ts // empty' "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$PENDING_TS" ]]; then
      remove_reaction "$CHANNEL_ID" "$PENDING_TS" "hourglass_flowing_sand"
      add_reaction    "$CHANNEL_ID" "$PENDING_TS" "white_check_mark"
      safe_state_update "$SID" 'del(.pending_user_ts)'
    fi

    # Mark session idle so daemon can drain any queued Slack messages.
    if [[ -f "$STATE_FILE" ]]; then
      safe_state_update "$SID" '. + {busy: false}'
    fi
    ;;

  end)
    # No state means we never created a channel for this session — nothing
    # to archive. Common case: cc-internal sub-session.
    if [[ ! -f "$STATE_FILE" ]]; then
      log "skip end (no state — sub-session) sid=$SID8"
      exit 0
    fi

    # Skip archive if this SessionEnd comes from a daemon-spawned
    # `claude -p --resume` inject — that's not the user closing the
    # session, just the resume subprocess finishing. The daemon writes
    # a marker before spawning, removes it after.
    FROM_SLACK_MARKER="$STATE_DIR/from-slack/$SID"
    if [[ -f "$FROM_SLACK_MARKER" ]] || [[ "${CC_BRIDGE_FROM_SLACK:-0}" = "1" ]]; then
      log "skip end (from-slack inject — not a real exit) sid=$SID8"
      exit 0
    fi

    # Phase 1.5 behavior: when SessionEnd fires for a session we have a
    # state file for, archive its channel. This is the original approach
    # that worked reliably — Claudian's "close conversation" + terminal
    # /exit both trigger SessionEnd cleanly. Sub-sessions don't have
    # state files (their user prompt was filtered as cc-internal noise),
    # so the no-state guard above already protects against false archives.
    CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
    if [[ -n "$CHANNEL_ID" ]]; then
      post_to_channel "$CHANNEL_ID" "_session ended ($CONTENT)_" \
        "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" >/dev/null
      archive_channel "$CHANNEL_ID"
    fi
    safe_state_update "$SID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '. + {archived: true, archived_at: $ts, archived_by: "session-end"}'
    ;;

  question)
    # PreToolUse for AskUserQuestion: cc is waiting for human input. Mirror
    # the question(s) + options to channel as Claude Code so the user knows
    # to come back to his desk. We don't try to answer from Slack — for
    # that we'd need to inject into the running CC session, which has no
    # public API yet.
    [[ "$(jq -r '.tool_name // empty' <<<"$PAYLOAD")" = "AskUserQuestion" ]] || exit 0
    [[ -f "$STATE_FILE" ]] || { log "skip question (no state — sub-session) sid=$SID8"; exit 0; }
    CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
    [[ -z "$CHANNEL_ID" ]] && exit 0

    # Render: each question becomes a block of text
    QTEXT="$(jq -r '
      [.tool_input.questions[] |
        ":grey_question: *" + .question + "*\n" +
        (
          [ .options | to_entries[] |
            "  • *" + .value.label + "* — " + (.value.description // "")
          ] | join("\n")
        )
      ] | join("\n\n")
    ' <<<"$PAYLOAD" 2>/dev/null)"
    [[ -z "$QTEXT" ]] && exit 0
    QTEXT=":grey_question: *Claude is waiting for your input* :grey_question:"$'\n\n'"$QTEXT" \
"\n\n_Reply in this channel to inject your answer remotely (experimental)._"
    post_to_channel "$CHANNEL_ID" "$QTEXT" "$CLAUDE_DISPLAY_NAME" "$CLAUDE_ICON_URL" \
      && log "ok role=question channel=$CHANNEL_ID sid=$SID8"

    # Experimental: flip busy=false so daemon will drain any queued
    # Slack messages — they get spawned via `claude -p --resume` and CC
    # decides how to interpret them given the pending AskUserQuestion in
    # the transcript. Worst case CC just opens a new turn instead of
    # answering the tool call; transcript stays valid either way.
    safe_state_update "$SID" '. + {busy: false}'

    # Swap the pending hourglass on the user prompt to a question mark
    # so the phone-side viewer sees "this is at AskUserQuestion" rather
    # than "still chewing". The pending_user_ts stays in state so a
    # later Stop hook can swap question-mark back to checkmark.
    PENDING_TS="$(jq -r '.pending_user_ts // empty' "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$PENDING_TS" ]]; then
      remove_reaction "$CHANNEL_ID" "$PENDING_TS" "hourglass_flowing_sand"
      add_reaction    "$CHANNEL_ID" "$PENDING_TS" "grey_question"
    fi
    ;;

  answer)
    # PostToolUse for AskUserQuestion: human answered. Mirror the chosen
    # labels back so the channel reflects what the user picked.
    [[ "$(jq -r '.tool_name // empty' <<<"$PAYLOAD")" = "AskUserQuestion" ]] || exit 0
    [[ -f "$STATE_FILE" ]] || exit 0
    CHANNEL_ID="$(jq -r '.channel_id // empty' "$STATE_FILE")"
    [[ -z "$CHANNEL_ID" ]] && exit 0

    ATEXT="$(jq -r '
      [(.tool_response.answers // .tool_input.answers // {}) | to_entries[] |
        "*" + .key + ":* " + .value
      ] | join("\n")
    ' <<<"$PAYLOAD" 2>/dev/null)"
    [[ -z "$ATEXT" ]] && exit 0
    ATEXT=":white_check_mark: *Answered*"$'\n'"$ATEXT"
    post_to_channel "$CHANNEL_ID" "$ATEXT" "$USER_DISPLAY_NAME" "$USER_ICON_URL" \
      && log "ok role=answer channel=$CHANNEL_ID sid=$SID8"

    # Replace the :grey_question: on the pending user prompt now that
    # the user answered locally. The model will resume its turn — the
    # next Stop hook will swap to :white_check_mark: and clear pending.
    PENDING_TS="$(jq -r '.pending_user_ts // empty' "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$PENDING_TS" ]]; then
      remove_reaction "$CHANNEL_ID" "$PENDING_TS" "grey_question"
      add_reaction    "$CHANNEL_ID" "$PENDING_TS" "hourglass_flowing_sand"
    fi
    ;;

  *)
    log "skip unknown role=$ROLE"
    ;;
esac

exit 0
