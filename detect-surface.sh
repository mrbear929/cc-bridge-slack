#!/usr/bin/env bash
# cc-bridge-slack/detect-surface.sh
#
# Best-effort detection of which surface (terminal app) is hosting the
# current Claude Code session. Echoes a short label like:
#   obsidian-claudian, obsidian-terminal, native-terminal, iterm,
#   warp, kiro, vscode, cursor, unknown
#
# Inputs:
#   $1 = transcript_path (optional). When provided, we read the transcript's
#        first entry to check `entrypoint` (sdk-ts vs cli) — sdk-ts +
#        Obsidian parent = Claudian.
#
# Strategy (in order):
#   1. transcript entrypoint == "sdk-ts" + Obsidian in ppid chain → claudian
#   2. ppid chain contains specific app bundles
#   3. TERM_PROGRAM env var
#   4. fall back to "unknown"

set -u

TRANSCRIPT="${1:-}"

# Entrypoint resolution order:
# 1. CLAUDE_CODE_ENTRYPOINT env var — set by CC at process start, ALWAYS
#    available when this hook runs (sdk-ts | cli)
# 2. transcript .entrypoint of first message — needs file flushed first,
#    sometimes empty when hook fires before user message is written
ENTRYPOINT="${CLAUDE_CODE_ENTRYPOINT:-}"
if [[ -z "$ENTRYPOINT" && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  ENTRYPOINT="$(jq -r '.entrypoint | select(. != null and . != "")' "$TRANSCRIPT" 2>/dev/null | head -1)"
fi

# Walk parent process tree (up to 20 levels), collect comm names lowercased.
# Hooks may be deeply nested: mirror.sh -> /bin/sh -> claude -> bash -> zsh
# -> python (terminal plugin) -> Obsidian Helper -> Obsidian.app, so 8 was
# too shallow.
ANCESTORS=""
PID=$PPID
for _ in $(seq 1 20); do
  COMM="$(ps -p "$PID" -o comm= 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [[ -z "$COMM" ]] && break
  ANCESTORS+="$COMM"$'\n'
  NEXT="$(ps -p "$PID" -o ppid= 2>/dev/null | tr -d ' ')"
  [[ -z "$NEXT" || "$NEXT" = "0" || "$NEXT" = "1" ]] && break
  PID="$NEXT"
done

ancestor_has() { grep -q "$1" <<<"$ANCESTORS"; }

# Optional debug: dump everything to log when caller asks
if [[ "${MIRROR_DEBUG_SURFACE:-0}" = "1" && -n "${MIRROR_LOG:-}" ]]; then
  {
    echo "[detect-surface debug] entrypoint=$ENTRYPOINT"
    echo "[detect-surface debug] ancestors:"
    printf '  %s\n' "$ANCESTORS"
    echo "[detect-surface debug] CFBundleId=${__CFBundleIdentifier:-}"
    echo "[detect-surface debug] TERM_PROGRAM=${TERM_PROGRAM:-}"
  } >>"$MIRROR_LOG" 2>/dev/null
fi

# Env-based pre-check: __CFBundleIdentifier survives subprocess inheritance
# even when ppid chain is somehow broken (sandboxed PTY, spawn-style fork).
case "${__CFBundleIdentifier:-}" in
  md.obsidian)
    if [[ "$ENTRYPOINT" = "sdk-ts" ]]; then
      echo "obsidian-claudian"; exit 0
    else
      echo "obsidian-terminal"; exit 0
    fi
    ;;
  com.googlecode.iterm2)  echo "iterm";           exit 0 ;;
  com.apple.Terminal)     echo "native-terminal"; exit 0 ;;
  dev.warp.Warp-Stable)   echo "warp";            exit 0 ;;
  com.todesktop.230313mzl4w4u92) echo "cursor";   exit 0 ;;
  com.microsoft.VSCode)   echo "vscode";          exit 0 ;;
esac

# Match in priority order
if ancestor_has 'obsidian'; then
  if [[ "$ENTRYPOINT" = "sdk-ts" ]]; then
    echo "obsidian-claudian"
  else
    echo "obsidian-terminal"
  fi
  exit 0
fi

if ancestor_has 'kiro'; then echo "kiro"; exit 0; fi
if ancestor_has 'cursor'; then echo "cursor"; exit 0; fi
if ancestor_has 'visual studio code\|/code helper\|code helper'; then echo "vscode"; exit 0; fi
if ancestor_has 'warp'; then echo "warp"; exit 0; fi
if ancestor_has 'iterm'; then echo "iterm"; exit 0; fi
if ancestor_has 'terminal\.app\|/terminal'; then echo "native-terminal"; exit 0; fi
if ancestor_has 'ghostty'; then echo "ghostty"; exit 0; fi
if ancestor_has 'alacritty'; then echo "alacritty"; exit 0; fi

# Fall back to TERM_PROGRAM
case "${TERM_PROGRAM:-}" in
  Apple_Terminal) echo "native-terminal"; exit 0 ;;
  iTerm.app)      echo "iterm";           exit 0 ;;
  WarpTerminal)   echo "warp";            exit 0 ;;
  vscode)         echo "vscode";          exit 0 ;;
  cursor)         echo "cursor";          exit 0 ;;
  ghostty)        echo "ghostty";         exit 0 ;;
esac

echo "unknown"
