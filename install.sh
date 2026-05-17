#!/usr/bin/env bash
# cc-bridge-slack/install.sh
#
# Bootstrap script — run on a new Mac (or after factory-reset) to install
# everything that lives outside this git repo:
#
#   1. macOS Keychain   ← bot token (interactive prompt)
#   2. ~/.claude/tools/slack-bridge.env   ← non-secret runtime config
#   3. ~/.claude/tools/cc-bridge-state/   ← per-session channel mappings
#   4. ~/.claude/settings.json hook block ← prints what to merge (manual paste)
#
# Idempotent: rerunning is safe — overwrites keychain item if you say yes,
# preserves existing env file, never modifies settings.json automatically.
#
# Usage:
#   ./install.sh

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$HOME/.claude/tools/slack-bridge.env"
STATE_DIR="$HOME/.claude/tools/cc-bridge-state"
KEYCHAIN_SERVICE="cc-bridge-slack"
KEYCHAIN_ACCOUNT="bot-token"

cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
gray()  { printf '\033[2m%s\033[0m\n' "$*"; }

cyan "==> cc-bridge-slack installer"
echo "Repo:    $REPO_DIR"
echo "Env:     $ENV_FILE"
echo "State:   $STATE_DIR"
echo

# ----- 1. Dependencies -------------------------------------------------------
cyan "==> checking dependencies"
need_cmd() { command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }; }
need_cmd jq
need_cmd curl
need_cmd security
need_cmd python3
green "✓ jq, curl, security, python3"
echo

# ----- 2. Keychain item ------------------------------------------------------
cyan "==> Slack bot token (macOS Keychain)"
if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w >/dev/null 2>&1; then
  green "✓ keychain item already exists ($KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)"
  read -rp "Overwrite with a new token? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rsp "Paste bot token (xoxb-...): " token; echo
    security add-generic-password -U -A -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$token"
    green "✓ token replaced"
  fi
else
  read -rsp "Paste bot token (xoxb-...): " token; echo
  if [[ -z "$token" ]]; then
    red "no token provided — aborting"
    exit 1
  fi
  security add-generic-password -U -A -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$token"
  green "✓ stored in keychain"
fi
echo

# ----- 3. Env file -----------------------------------------------------------
cyan "==> non-secret config ($ENV_FILE)"
mkdir -p "$(dirname "$ENV_FILE")"
if [[ -f "$ENV_FILE" ]]; then
  green "✓ $ENV_FILE already exists — leaving as-is"
  gray "  (delete it manually if you want a fresh template)"
else
  read -rp "Slack user ID (U... format, your member ID): " user_id
  read -rp "Bear icon URL (https://ca.slack-edge.com/...): " bear_url
  read -rp "Claude icon URL (or empty for app default): " claude_url
  cat >"$ENV_FILE" <<ENVEOF
# cc-bridge-slack runtime config (non-secret)
# Bot token lives in macOS Keychain ($KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)
SLACK_USER_ID=$user_id
BEAR_DISPLAY_NAME="Bear"
BEAR_ICON_URL="$bear_url"
CLAUDE_DISPLAY_NAME="Claude Code"
CLAUDE_ICON_URL="$claude_url"
MIRROR_TAG="cc"
MIRROR_DRY_RUN=0
ENVEOF
  chmod 600 "$ENV_FILE"
  green "✓ wrote $ENV_FILE (mode 600)"
fi
echo

# ----- 4. State dir ----------------------------------------------------------
cyan "==> state directory"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
green "✓ $STATE_DIR (mode 700)"
echo

# ----- 5. Hook block instructions --------------------------------------------
cyan "==> Claude Code hook configuration"
SETTINGS="$HOME/.claude/settings.json"
HOOK_BLOCK=$(cat "$REPO_DIR/settings.test.json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(json.dumps(data["hooks"], indent=2))
')

if [[ -f "$SETTINGS" ]] && python3 -c "
import json, sys
d = json.load(open('$SETTINGS'))
sys.exit(0 if 'hooks' in d and 'UserPromptSubmit' in d.get('hooks', {}) else 1)
" 2>/dev/null; then
  green "✓ $SETTINGS already has hooks configured"
  gray "  verify it points at: $REPO_DIR/mirror.sh"
else
  echo "Add this block to $SETTINGS at the top level:"
  echo
  printf '"hooks": '
  echo "$HOOK_BLOCK"
  echo
  gray "(remember to add a comma after the previous top-level field)"
fi
echo

# ----- 6. Smoke test ---------------------------------------------------------
cyan "==> smoke test"
if "$REPO_DIR/mirror.sh" user <<<'{"session_id":"smoke-test-0000","cwd":"'"$PWD"'","prompt":"installer smoke test","transcript_path":""}' >/dev/null 2>&1; then
  if [[ -f "$STATE_DIR/smoke-test-0000.json" ]]; then
    rm -f "$STATE_DIR/smoke-test-0000.json"
  fi
  green "✓ mirror.sh ran without error"
  gray "  check /tmp/cc-mirror-test.log to confirm it actually posted"
else
  red "✗ mirror.sh failed"
  gray "  check /tmp/cc-mirror-test.log for the error"
fi
echo

green "==> install complete"
echo "Next:"
echo "  1. Add hook block to ~/.claude/settings.json (printed above)"
echo "  2. Open a new Claude Code session in any project"
echo "  3. Send any prompt — a private channel should appear in your sandbox"
