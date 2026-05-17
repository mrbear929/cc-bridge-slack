#!/usr/bin/env bash
# One-shot diagnostic. Run this from each terminal/surface you use to see
# exactly what process chain + env vars the detect script can see. Prints
# what detect-surface.sh decides.

OUT=/tmp/cc-bridge-surface-dump.txt
{
  echo "=== $(date) ==="
  echo "PWD: $(pwd)"
  echo
  echo "--- relevant env ---"
  env | grep -iE '(TERM_PROGRAM|TERM_SESSION|OBSIDIAN|KIRO|ITERM|VSCODE|CLAUDIAN|ELECTRON|FLEETVIEW|__CFBUNDLE|CONFIG_DIR)' | sort
  echo
  echo "--- ppid chain ---"
  PID=$$
  for i in 1 2 3 4 5 6 7 8; do
    COMM="$(ps -p "$PID" -o comm= 2>/dev/null)"
    [[ -z "$COMM" ]] && break
    PPID_VAL="$(ps -p "$PID" -o ppid= 2>/dev/null | tr -d ' ')"
    echo "depth=$i pid=$PID ppid=$PPID_VAL comm=$COMM"
    [[ -z "$PPID_VAL" || "$PPID_VAL" = "0" || "$PPID_VAL" = "1" ]] && break
    PID="$PPID_VAL"
  done
  echo
  echo "--- detect-surface result ---"
  "$(dirname "$0")/detect-surface.sh"
  echo
} | tee -a "$OUT"
echo "(appended to $OUT)"
