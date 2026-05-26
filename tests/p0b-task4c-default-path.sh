#!/usr/bin/env bash
# Task 4c: default-path shorthand for DM `new`.
#
# (a) `new <prompt>`           → spawns at ~/Documents/obsidian-vault
# (b) `new summarize: tldr`    → "summarize" is NOT a path; whole body is the
#                                prompt (cwd defaults to vault)
# (c) `new /tmp: ls`           → explicit path still works
# (d) ``new the top todos``    → backticks + default path

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/.claude/tools/cc-bridge-state"
VAULT="$HOME/Documents/obsidian-vault"
TOKEN="$(security find-generic-password -s cc-bridge-slack -a bot-token -w)"

pass=0; fail=0
say() { printf '[%s] %s\n' "$1" "$2"; }
ok()  { say PASS "$1"; pass=$((pass+1)); }
ko()  { say FAIL "$1"; fail=$((fail+1)); }

call_handler() {
  cd "$REPO/daemon" && uv run python -c "
import sys
from main import handle_new_session
print(handle_new_session(sys.argv[1]))
" "$1" 2>&1 | tail -20 | grep -vE '^(Using|Creating|Installed|Resolved|Audited|Built|Reading|warning:)' | tail -1
}

newest_state_cwd() {
  ls -t "$STATE_DIR"/*.json 2>/dev/null | head -1 | xargs -I {} jq -r '.cwd' {}
}

# --- (a) bare prompt → default path --------------------------------------
say INFO "(a) bare prompt defaults to vault"
resp=$(call_handler "new tell me 1 plus 1")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(a) channel returned"
  sleep 2
  cwd=$(newest_state_cwd)
  expected=$(python3 -c "import os; print(os.path.realpath('$VAULT'))")
  cwd_real=$(python3 -c "import os; print(os.path.realpath('$cwd'))")
  [[ "$cwd_real" = "$expected" ]] && ok "(a) cwd defaulted to vault" || ko "(a) cwd=$cwd (expected $expected)"
else
  ko "(a) failed: $resp"
fi
sleep 30  # let CC finish before the next test reuses the watcher

# --- (b) prompt with colon but no path-ish prefix ------------------------
say INFO "(b) 'new summarize: tldr' → prompt contains colon, default path"
resp=$(call_handler "new summarize: 1 plus 1 in two words")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(b) channel returned"
  sleep 2
  cwd=$(newest_state_cwd)
  cwd_real=$(python3 -c "import os; print(os.path.realpath('$cwd'))")
  expected=$(python3 -c "import os; print(os.path.realpath('$VAULT'))")
  [[ "$cwd_real" = "$expected" ]] && ok "(b) cwd defaulted (colon was part of prompt)" || ko "(b) cwd=$cwd_real"
else
  ko "(b) failed: $resp"
fi
sleep 30

# --- (c) explicit path still works ---------------------------------------
say INFO "(c) explicit path still works"
mkdir -p /tmp/cc-bridge-test
resp=$(call_handler "new /tmp/cc-bridge-test: tell me yes")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(c) explicit path channel returned"
  sleep 2
  cwd=$(newest_state_cwd)
  cwd_real=$(python3 -c "import os; print(os.path.realpath('$cwd'))")
  expected=$(python3 -c "import os; print(os.path.realpath('/tmp/cc-bridge-test'))")
  [[ "$cwd_real" = "$expected" ]] && ok "(c) explicit path honored" || ko "(c) cwd=$cwd_real"
else
  ko "(c) failed: $resp"
fi
sleep 30

# --- (d) backticks + default path ----------------------------------------
say INFO "(d) backticks + default path"
resp=$(call_handler "\`new what is 2 plus 2\`")
echo "  response: $resp"
if echo "$resp" | grep -qE '<#C[A-Z0-9]+> ready'; then
  ok "(d) backticks stripped, channel returned"
else
  ko "(d) failed: $resp"
fi

echo
echo "=== Task 4c results: $pass pass, $fail fail ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
