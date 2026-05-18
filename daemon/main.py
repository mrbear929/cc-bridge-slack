#!/usr/bin/env python3
"""
cc-bridge-slack daemon (Phase 2).

A Socket Mode listener that:
  - watches for direct messages to the cc-bridge bot
  - parses commands like "start cc-bridge", "stop cc-bridge", "active"
  - routes free-form replies into the matching CC session via
    `claude -p --resume <sid>`
  - posts the streaming output back into the originating Slack channel

Phase 2 starts with command parsing (start/stop/active) and ends with
full bidirectional control. Built incrementally.

Tokens:
  xoxb-... (bot token)        — read from macOS Keychain
                                  service=cc-bridge-slack account=bot-token
  xapp-... (app-level token)  — read from env var SLACK_APP_TOKEN
                                  (loaded from Apple Passwords by hand
                                   for now; can wire keyring helper later)

Run interactively:
  cd dev/tools/cc-bridge-slack/daemon
  source .venv/bin/activate
  SLACK_APP_TOKEN=xapp-... python main.py
"""

from __future__ import annotations

import json
import logging
import os
import pathlib
import subprocess
import sys
import threading
from typing import Any

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

STATE_DIR = pathlib.Path(os.path.expanduser("~/.claude/tools/cc-bridge-state"))
LOG_FILE = pathlib.Path("/tmp/cc-bridge-daemon.log")

KEYCHAIN_SERVICE = "cc-bridge-slack"
KEYCHAIN_BOT_ACCOUNT = "bot-token"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()],
)
log = logging.getLogger("cc-bridge")


def get_bot_token() -> str:
    """Read xoxb- from macOS Keychain via the `security` CLI."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password",
             "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_BOT_ACCOUNT, "-w"],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        log.error("could not read bot token from keychain: %s", e.stderr)
        sys.exit(1)


def get_app_token() -> str:
    token = os.environ.get("SLACK_APP_TOKEN")
    if not token:
        log.error(
            "SLACK_APP_TOKEN env var not set. Get xapp- token from Apple "
            "Passwords (cc-bridge xapp Socket Mode) and export before running."
        )
        sys.exit(1)
    return token


def is_enabled() -> bool:
    """Default ON — only off if Bear has explicitly stopped via DM."""
    return not (STATE_DIR / "disabled").exists()


def set_enabled(enabled: bool) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    flag = STATE_DIR / "disabled"
    if enabled:
        flag.unlink(missing_ok=True)
    else:
        flag.touch()


app = App(token=get_bot_token())


def channel_to_session(channel_id: str) -> dict[str, Any] | None:
    """Find the state file for a channel id. Returns full state dict or None."""
    for f in STATE_DIR.glob("*.json"):
        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        if d.get("channel_id") == channel_id and not d.get("archived"):
            return d
    return None


@app.event("message")
def on_message(event: dict[str, Any], client, say) -> None:
    """Route messages: DMs to bot = commands; messages in tracked channels = reply injections."""
    # Ignore subtypes (edits, deletions, etc.) and bot's own posts
    subtype = event.get("subtype")
    if subtype in ("message_changed", "message_deleted", "channel_join", "channel_topic"):
        return
    # bot_message subtype = ANY bot's post; we also need to skip our own
    # username-overridden posts (mirror.sh's Bear/Claude Code), which arrive
    # as bot_message + bot_id matching our own bot
    if subtype == "bot_message":
        return
    if event.get("bot_id"):
        return

    text = (event.get("text") or "").strip()
    if not text:
        return

    channel_type = event.get("channel_type")
    channel_id = event.get("channel")
    user = event.get("user")
    event_ts = event.get("ts")

    # ── DM commands ───────────────────────────────────────────────────────
    if channel_type == "im":
        log.info("DM from %s: %s", user, text)
        cmd = text.lower()
        if cmd in ("start cc-bridge", "start", "resume"):
            set_enabled(True)
            say(":white_check_mark: cc-bridge enabled. New CC sessions will be mirrored.")
            return
        if cmd in ("stop cc-bridge", "stop", "pause"):
            set_enabled(False)
            say(":pause_button: cc-bridge paused. Send `start` to resume.")
            return
        if cmd in ("status", "?"):
            state = "enabled" if is_enabled() else "paused"
            say(f"cc-bridge is currently *{state}*.")
            return
        if cmd in ("active", "list", "sessions"):
            active = list_active_sessions()
            if not active:
                say("No active CC sessions tracked.")
                return
            lines = [
                f"• <#{s['channel_id']}> — surface `{s.get('surface','?')}`, cwd `{s.get('cwd','?')}`"
                for s in active
            ]
            say("Active sessions:\n" + "\n".join(lines))
            return

        say(
            "Commands:\n"
            "• `start` / `stop` — toggle mirroring of new CC sessions\n"
            "• `status` — am I on?\n"
            "• `active` — list running sessions\n"
            "_To reply to a session, message in its channel directly._"
        )
        return

    # ── Reply routing in session channels ────────────────────────────────
    # Any private channel that maps to a known active CC session: treat the
    # message as a new prompt to inject via `claude -p --resume`.
    state = channel_to_session(channel_id) if channel_id else None
    if state is None:
        return  # not a tracked session channel — ignore

    sid = state["session_id"]
    log.info("reply route channel=%s sid=%s text=%r", channel_id, sid[:8], text[:60])

    # Ack with reaction (synchronous, before launching the subprocess)
    try:
        client.reactions_add(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
    except Exception as e:
        log.warning("could not add ack reaction: %s", e)

    def runner() -> None:
        try:
            # Build a clean env: drop CLAUDE_CODE_* leakage from the parent
            # process so the subprocess doesn't inherit "I am session X".
            # Also set CWD to the session's cwd so CC finds the project's
            # transcript directory.
            child_env = os.environ.copy()
            for k in list(child_env.keys()):
                if k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE" or k == "AI_AGENT":
                    del child_env[k]

            cwd = state.get("cwd") or os.path.expanduser("~")
            if not os.path.isdir(cwd):
                cwd = os.path.expanduser("~")

            result = subprocess.run(
                ["claude", "-p", "--resume", sid, "--output-format", "text", text],
                capture_output=True,
                text=True,
                timeout=600,
                env=child_env,
                cwd=cwd,
            )
            if result.returncode != 0:
                log.error("claude -p exit=%d stderr=%s", result.returncode, result.stderr[:500])
                client.chat_postMessage(
                    channel=channel_id,
                    text=f":x: Inject failed: `{result.stderr.splitlines()[-1] if result.stderr else 'unknown error'}`",
                )
        except subprocess.TimeoutExpired:
            log.error("claude -p timed out 600s sid=%s", sid[:8])
            client.chat_postMessage(channel=channel_id, text=":x: Inject timed out (>10 min)")
        except Exception as e:
            log.error("claude -p exception sid=%s: %s", sid[:8], e)
            client.chat_postMessage(channel=channel_id, text=f":x: Inject crashed: `{e}`")
        finally:
            try:
                client.reactions_remove(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
                client.reactions_add(channel=channel_id, name="white_check_mark", timestamp=event_ts)
            except Exception:
                pass

    threading.Thread(target=runner, daemon=True).start()


def list_active_sessions() -> list[dict[str, Any]]:
    out = []
    for f in sorted(STATE_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        if d.get("archived"):
            continue
        out.append(d)
    return out


def get_alive_session_ids() -> set[str]:
    """Return CLAUDE_CODE_SESSION_ID values for any running cc process,
    excluding our own daemon process tree (which inherits the env var
    from whichever shell launched us)."""
    try:
        # ps -E -axww gives "PID TT STAT TIME CMD env=val env=val ..."
        result = subprocess.run(
            ["ps", "-E", "-axww", "-o", "pid=,command="],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError:
        return set()

    own_pid = os.getpid()
    own_pgid = os.getpgid(0)
    alive: set[str] = set()
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        cmd = parts[1]

        # Skip our own process tree (daemon + its children inherit
        # CLAUDE_CODE_SESSION_ID from the shell that launched us)
        if pid == own_pid:
            continue
        try:
            if os.getpgid(pid) == own_pgid:
                continue
        except (ProcessLookupError, PermissionError):
            pass

        # Extract session id from env list embedded in cmd
        for tok in cmd.split():
            if tok.startswith("CLAUDE_CODE_SESSION_ID="):
                sid = tok.split("=", 1)[1]
                if sid:
                    alive.add(sid)
                break
    return alive


def archive_channel_via_api(channel_id: str) -> None:
    try:
        app.client.conversations_archive(channel=channel_id)
    except Exception as e:
        log.warning("archive failed channel=%s: %s", channel_id, e)


def sweep_dead_sessions() -> None:
    """Background sweeper: every 5s, archive channels whose CC process
    is no longer running. Replaces the SessionEnd hook (unreliable).
    Uses creation timestamp (not mtime) for grace period to avoid
    re-arming on every state file write."""
    import time
    from datetime import datetime, timezone
    log.info("sweeper started (5s interval)")
    while True:
        try:
            alive = get_alive_session_ids()
            now = datetime.now(timezone.utc)
            now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
            for state_file in STATE_DIR.glob("*.json"):
                try:
                    state = json.loads(state_file.read_text())
                except json.JSONDecodeError:
                    continue
                if state.get("archived"):
                    continue
                sid = state.get("session_id")
                if not sid or sid in alive:
                    continue
                channel_id = state.get("channel_id")
                if not channel_id:
                    continue
                # Grace period 15s based on .created field (not mtime —
                # mtime updates whenever we touch state). Protects only
                # newly-created sessions whose process may not yet appear
                # in ps output.
                created_str = state.get("created", "")
                try:
                    created = datetime.fromisoformat(
                        created_str.replace("Z", "+00:00")
                    )
                    age = (now - created).total_seconds()
                except Exception:
                    age = 999  # unknown → assume old
                if age < 15:
                    continue
                log.info("archiving dead session sid=%s channel=%s age=%ds",
                         sid[:8], channel_id, int(age))
                archive_channel_via_api(channel_id)
                state["archived"] = True
                state["archived_at"] = now_iso
                state["archived_by"] = "sweeper"
                state_file.write_text(json.dumps(state, indent=2))
        except Exception as e:
            log.error("sweeper iteration crashed: %s", e)
        time.sleep(5)


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log.info("starting cc-bridge daemon (state=%s)", STATE_DIR)

    # Sweeper disabled. Phase 1.5's SessionEnd hook is reliable when we
    # don't second-guess it (sub-sessions filtered by no-state-file
    # guard, real exits archive cleanly). Reopening an old session
    # auto-unarchives via mirror.sh ensure_channel.
    # threading.Thread(target=sweep_dead_sessions, daemon=True).start()

    handler = SocketModeHandler(app, get_app_token())
    handler.start()


if __name__ == "__main__":
    main()
