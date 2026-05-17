#!/usr/bin/env bash
# cc-bridge-slack/daemon/run.sh
# Wrapper invoked by launchd. Loads the xapp- token from a local file
# (written by install.sh from Apple Passwords) and execs main.py via uv.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$HOME/.claude/tools/slack-bridge-app.token"

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "ERROR: $TOKEN_FILE missing. Run install.sh and paste xapp- token from Apple Passwords." >&2
  exit 1
fi

SLACK_APP_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
export SLACK_APP_TOKEN

cd "$DIR"
exec uv run python main.py
