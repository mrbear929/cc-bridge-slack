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


@app.event("message")
def on_message(event: dict[str, Any], say) -> None:
    """Handle DMs to the bot (channel_type == 'im')."""
    if event.get("subtype") in ("bot_message", "message_changed", "message_deleted"):
        return
    if event.get("channel_type") != "im":
        return

    user = event.get("user")
    text = (event.get("text") or "").strip()
    if not text:
        return

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
        "Commands I understand:\n"
        "• `start` / `stop` — toggle mirroring of new CC sessions\n"
        "• `status` — am I on?\n"
        "• `active` — list currently running sessions\n"
        "_(Bidirectional reply routing coming next.)_"
    )


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


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log.info("starting cc-bridge daemon (state=%s)", STATE_DIR)
    handler = SocketModeHandler(app, get_app_token())
    handler.start()


if __name__ == "__main__":
    main()
