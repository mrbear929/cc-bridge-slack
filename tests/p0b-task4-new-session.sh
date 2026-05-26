#!/usr/bin/env bash
# Task 4 acceptance test: DM `new <path>: <prompt>` mobile-initiated session.
#
# (a) Happy path — `new /tmp/cc-bridge-test: prompt` spawns CC, channel appears.
# (b) Multi-line variant — same outcome.
# (c) Bad path — error response, no channel.
# (d) No body — usage text.
# (e) Tilde expansion — path resolves and runs.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/.claude/tools/cc-bridge-state"
TEST_CWD="/tmp/cc-bridge-test"
mkdir -p "$TEST_CWD"

pass=0; fail=0
say() { printf '[%s] %s\n' "$1" "$2"; }
ok()  { say PASS "$1"; pass=$((pass+1)); }
ko()  { say FAIL "$1"; fail=$((fail+1)); }

call_handler() {
  # call_handler "<text>" → echoes the response string
  cd "$REPO/daemon" && uv run python -c "
import sys
from main import handle_new_session
print(handle_new_session(sys.argv[1]))
" "$1" 2>&1 | tail -20 | grep -vE '^(Using|Creating|Installed|Resolved|Audited|Built|Reading|warning:)' | tail -1
}

# --- (c) Bad path ---------------------------------------------------------
say INFO "(c) bad path → error string"
resp=$(call_handler "new /no/such/path: hi")
echo "  response: $resp"
if echo "$resp" | grep -qE 'path not a directory'; then
  ok "(c) error response correct"
else
  ko "(c) wrong response: $resp"
fi

# --- (d) No body ---------------------------------------------------------
say INFO "(d) no body → usage"
resp=$(call_handler "new")
echo "  response: $resp"
if echo "$resp" | grep -qE 'usage:.*new'; then
  ok "(d) usage shown"
else
  ko "(d) wrong response: $resp"
fi

resp=$(call_handler "new   ")
echo "  response: $resp"
if echo "$resp" | grep -qE 'usage:.*new'; then
  ok "(d) usage shown (trailing whitespace only)"
else
  ko "(d) whitespace-only failed: $resp"
fi

# --- (a) Happy path ------------------------------------------------------
say INFO "(a) happy path: new $TEST_CWD: respond with literal word ok"
# Note state files snapshot before
before=$(ls "$STATE_DIR"/*.json 2>/dev/null | wc -l)

resp=$(call_handler "new $TEST_CWD: respond with the literal word ok")
echo "  response: $resp"

# Channel link in response?
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(a) response contains channel link"
else
  ko "(a) no channel link: $resp"
fi

# Find newest state file. Compare via python realpath so /tmp ↔ /private/tmp
# on macOS doesn't trip the assertion.
sleep 2
newest=$(ls -t "$STATE_DIR"/*.json 2>/dev/null | head -1)
if [[ -n "$newest" ]]; then
  cwd=$(jq -r '.cwd // ""' "$newest")
  expected_real=$(python3 -c "import os; print(os.path.realpath('$TEST_CWD'))")
  cwd_real=$(python3 -c "import os; print(os.path.realpath('$cwd'))")
  if [[ "$cwd_real" = "$expected_real" ]]; then
    ok "(a) newest state has cwd matching $TEST_CWD (resolved=$cwd_real)"
  else
    ko "(a) newest state cwd=$cwd_real (expected $expected_real)"
  fi
else
  ko "(a) no state file appeared"
fi

# Wait for CC to finish so subsequent tests have clean state
sleep 30

# --- (b) Multi-line variant ----------------------------------------------
say INFO "(b) multi-line variant"
resp=$(call_handler "new $TEST_CWD
respond with the literal word ok")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(b) multi-line channel link returned"
else
  ko "(b) multi-line failed: $resp"
fi
sleep 30

# --- (e) Tilde expansion -------------------------------------------------
say INFO "(e) tilde expansion"
resp=$(call_handler "new ~/Documents/obsidian-vault: tell me 1 plus 1")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(e) tilde path resolved and ran"
else
  ko "(e) tilde failed: $resp"
fi

echo
echo "=== Task 4 results: $pass pass, $fail fail ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
