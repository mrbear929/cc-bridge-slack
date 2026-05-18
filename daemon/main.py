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
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

STATE_DIR = pathlib.Path(os.path.expanduser("~/.claude/tools/cc-bridge-state"))
LOG_FILE = pathlib.Path("/tmp/cc-bridge-daemon.log")
ENV_FILE = pathlib.Path(os.path.expanduser("~/.claude/tools/slack-bridge.env"))

KEYCHAIN_SERVICE = "cc-bridge-slack"
KEYCHAIN_BOT_ACCOUNT = "bot-token"


def load_env_file() -> dict[str, str]:
    """Load shell-style env file (KEY=value) into a plain dict."""
    out: dict[str, str] = {}
    if not ENV_FILE.exists():
        return out
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


CONFIG = load_env_file()
ALLOWED_USER_ID = CONFIG.get("SLACK_USER_ID", "")

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


# ──────────────────────────────────────────────────────────────────────
# Per-sid state-file locking.
# mirror.sh uses mkdir on $STATE_DIR/.lock-$sid as its mutex; we use the
# same dir so the two coordinate. fcntl.flock is per-fd which doesn't
# help across processes the same way, so we mirror mirror.sh's scheme.
# ──────────────────────────────────────────────────────────────────────


@contextmanager
def state_lock(sid: str, timeout_s: float = 5.0):
    lockdir = STATE_DIR / f".lock-{sid}"
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            lockdir.mkdir()
            break
        except FileExistsError:
            # Stale-lock cleanup: > 10s old means a previous holder crashed.
            try:
                age = time.time() - lockdir.stat().st_mtime
                if age > 10:
                    lockdir.rmdir()
                    continue
            except FileNotFoundError:
                continue
            if time.monotonic() > deadline:
                log.warning("state lock timeout sid=%s — proceeding without lock", sid[:8])
                yield
                return
            time.sleep(0.1)
    try:
        yield
    finally:
        try:
            lockdir.rmdir()
        except FileNotFoundError:
            pass


def state_update(sid: str, mutator) -> dict[str, Any] | None:
    """Atomically read+mutate+write state file. mutator(dict)->dict."""
    f = STATE_DIR / f"{sid}.json"
    if not f.exists():
        return None
    with state_lock(sid):
        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError:
            return None
        new = mutator(d)
        if new is not None:
            f.write_text(json.dumps(new, indent=2))
            return new
        return d


# Per-sid concurrency cap on `claude -p --resume` spawns. Without this,
# a flood of Slack messages could fan out to dozens of subprocesses
# all clobbering the same transcript file.
_inject_locks: dict[str, threading.Lock] = {}
_inject_locks_guard = threading.Lock()


def inject_lock_for(sid: str) -> threading.Lock:
    with _inject_locks_guard:
        if sid not in _inject_locks:
            _inject_locks[sid] = threading.Lock()
        return _inject_locks[sid]


def sid_has_live_process(sid: str) -> bool:
    """Return True if a *foreign* CC process (terminal / Claudian) is
    currently running for this sid. We don't want to spawn our own
    `claude -p --resume` while the local user's session is still alive
    — it would race them on transcript writes.

    Skips processes in the daemon's own process group (those are our
    cc-resume children). Skips `-p --resume` invocations specifically
    to avoid counting our own already-spawned drain workers when a
    second message arrives.
    """
    try:
        result = subprocess.run(
            ["ps", "-axww", "-o", "pid=,pgid=,command="],
            capture_output=True, text=True, check=True, timeout=2,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    own_pgid = os.getpgid(0)
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid_n = int(parts[0]); pgid_n = int(parts[1])
        except ValueError:
            continue
        cmd = parts[2]
        if "claude" not in cmd or sid not in cmd:
            continue
        # Skip our own children (same process group as the daemon)
        if pgid_n == own_pgid:
            continue
        # Belt-and-suspenders: skip cc-resume invocations regardless of pgid
        if " -p " in cmd and "--resume" in cmd:
            continue
        return True
    return False


def is_enabled() -> bool:
    """Default ON — only off if the user has explicitly stopped via DM."""
    return not (STATE_DIR / "disabled").exists()


def set_enabled(enabled: bool) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    flag = STATE_DIR / "disabled"
    if enabled:
        flag.unlink(missing_ok=True)
    else:
        flag.touch()


app = App(token=get_bot_token())


def enqueue(sid: str, text: str, channel_id: str, ts: str) -> None:
    """Append a queued message to the per-session queue file."""
    qdir = STATE_DIR / "queue"
    qdir.mkdir(exist_ok=True)
    qfile = qdir / f"{sid}.jsonl"
    with qfile.open("a") as f:
        f.write(json.dumps({"text": text, "channel_id": channel_id, "ts": ts}) + "\n")


def drain_queue_for_sid(sid: str) -> None:
    """Run any pending queued messages for sid through claude -p --resume.
    Called from the queue drainer thread when it observes busy=false."""
    qfile = STATE_DIR / "queue" / f"{sid}.jsonl"
    if not qfile.exists():
        return
    state_file = STATE_DIR / f"{sid}.json"
    if not state_file.exists():
        return
    try:
        state = json.loads(state_file.read_text())
    except json.JSONDecodeError:
        return

    # Atomically claim queue contents — rename then read, so any
    # concurrent enqueue lands in a fresh file (which the next loop tick
    # will pick up).
    claim = qfile.with_suffix(f".jsonl.claim-{os.getpid()}")
    try:
        qfile.rename(claim)
    except FileNotFoundError:
        return
    queued_lines = claim.read_text().splitlines()
    claim.unlink(missing_ok=True)
    if not queued_lines:
        return

    log.info("draining %d queued message(s) for sid=%s", len(queued_lines), sid[:8])

    cwd = state.get("cwd") or os.path.expanduser("~")
    if not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")
    child_env = os.environ.copy()
    for k in list(child_env.keys()):
        if k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE" or k == "AI_AGENT":
            del child_env[k]
    # Tell mirror.sh hooks this turn was injected from Slack; user prompt
    # mirror should be skipped (your xzixuan message is already there).
    child_env["CC_BRIDGE_FROM_SLACK"] = "1"

    # File-based marker (env vars don't survive CC's hook spawn).
    marker_dir = STATE_DIR / "from-slack"
    marker_dir.mkdir(parents=True, exist_ok=True)
    marker = marker_dir / sid

    for raw in queued_lines:
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        text = entry["text"]
        channel_id = entry["channel_id"]
        ts = entry["ts"]
        try:
            app.client.reactions_remove(channel=channel_id, name="hourglass_flowing_sand", timestamp=ts)
        except Exception:
            pass
        try:
            marker.touch()
            result = subprocess.run(
                ["claude", "-p", "--resume", sid, "--permission-mode", "bypassPermissions", "--output-format", "text", text],
                capture_output=True, text=True, timeout=600, env=child_env, cwd=cwd,
            )
            if result.returncode != 0:
                log.error("queued claude -p exit=%d stderr=%s", result.returncode, result.stderr[:300])
        except Exception as e:
            log.error("queued claude -p crashed: %s", e)
        finally:
            marker.unlink(missing_ok=True)
        try:
            app.client.reactions_add(channel=channel_id, name="white_check_mark", timestamp=ts)
        except Exception:
            pass


def queue_drain_loop() -> None:
    """Watch state files; whenever a session has queued messages and busy=false,
    drain them. Polls every 2s — short enough that idle gaps get used, long
    enough not to thrash the file system."""
    import time
    while True:
        try:
            qdir = STATE_DIR / "queue"
            if qdir.exists():
                for qfile in qdir.glob("*.jsonl"):
                    sid = qfile.stem
                    state_file = STATE_DIR / f"{sid}.json"
                    if not state_file.exists():
                        # state gone (session archived) — flush queue
                        qfile.unlink(missing_ok=True)
                        continue
                    try:
                        state = json.loads(state_file.read_text())
                    except json.JSONDecodeError:
                        continue
                    if state.get("busy") or sid_has_live_process(sid):
                        continue  # still mid-turn (busy flag OR ps shows live CC)
                    drain_queue_for_sid(sid)
        except Exception as e:
            log.error("queue drain loop crashed: %s", e)
        time.sleep(2)


def channel_to_session(channel_id: str) -> dict[str, Any] | None:
    """Find the state file for a channel id. Returns full state dict or None.

    If the state file says archived but Slack-side the channel was just
    unarchived (e.g. user manually clicked unarchive), trust the Slack
    side: clear the archived flag in state and return the dict. This
    handles the case where the user unarchives an old session channel and
    expects to be able to inject prompts via Slack.
    """
    for f in STATE_DIR.glob("*.json"):
        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        if d.get("channel_id") != channel_id:
            continue
        if d.get("archived"):
            # Verify with Slack — if channel is unarchived, sync state and proceed.
            try:
                resp = app.client.conversations_info(channel=channel_id)
                if not resp["channel"].get("is_archived"):
                    log.info("state stale: %s says archived but slack says unarchived — syncing", channel_id)
                    sid = d.get("session_id", "")
                    def _clear(s: dict) -> dict:
                        for k in ("archived", "archived_at", "archived_by"):
                            s.pop(k, None)
                        return s
                    updated = state_update(sid, _clear)
                    return updated or d
            except Exception as e:
                log.warning("could not verify channel state: %s", e)
            return None
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
    # username-overridden posts (mirror.sh user/Claude Code overrides), which arrive
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

    # Hard-gate by user id. Without this, anyone the bot is added to a
    # shared channel with could drive `claude -p --resume bypassPermissions`
    # — full FS/network execution on the host machine. The sandbox workspace
    # is single-user (you are admin), so any non-self user_id reaching
    # us means a misconfigured invite. Refuse loudly.
    if ALLOWED_USER_ID and user and user != ALLOWED_USER_ID:
        log.warning("rejected non-allowed user=%s channel=%s", user, channel_id)
        return

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
        if cmd in ("recent", "archived"):
            recents = list_recently_archived(limit=10)
            if not recents:
                say("No recently-archived sessions.")
                return
            lines = []
            for s in recents:
                title = s.get("title") or s.get("channel_name") or s.get("session_id", "")[:8]
                age = _humanize_age(s.get("archived_at", ""))
                lines.append(f"• <#{s['channel_id']}|{s.get('channel_name','?')}> — {title} ({age})")
            say("Recently archived:\n" + "\n".join(lines) +
                "\n_Click a channel to unarchive and reply._")
            return

        say(
            "Commands:\n"
            "• `start` / `stop` — toggle mirroring of new CC sessions\n"
            "• `status` — am I on?\n"
            "• `active` — list running sessions\n"
            "• `recent` — list recently-archived sessions\n"
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

    # ── In-channel exit command ─────────────────────────────────────────
    # Plain words: exit / end / archive. Can't use leading slash —
    # Slack intercepts slash commands client-side and they never reach
    # our message events. Doesn't kill the running CC process (we can't
    # safely; could be mid tool use). Matches mirror.sh's archive_channel
    # logic so SessionEnd-driven archive stays consistent.
    cmd = text.strip().lower()
    if cmd in ("exit", "end", "archive"):
        log.info("channel-exit channel=%s sid=%s", channel_id, sid[:8])
        # Mark state archived (mirror.sh end case writes the same fields).
        def _mark_archived(d: dict) -> dict:
            d["archived"] = True
            d["archived_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            d["archived_by"] = "slack-channel-exit"
            return d
        state_update(sid, _mark_archived)
        # Post a closing marker as Claude Code identity (consistent with
        # the SessionEnd hook's "_session ended (...)_" line) and archive.
        try:
            client.chat_postMessage(
                channel=channel_id,
                text="_session ended (exit from Slack)_",
                username="Claude Code",
                mrkdwn=True,
            )
        except Exception:
            pass
        try:
            client.conversations_archive(channel=channel_id)
        except Exception as e:
            log.warning("could not archive: %s", e)
        # ack with check on the user's /exit message
        try:
            client.reactions_add(channel=channel_id, name="white_check_mark", timestamp=event_ts)
        except Exception:
            pass
        return

    log.info("reply route channel=%s sid=%s text=%r", channel_id, sid[:8], text[:60])

    # Ack with reaction. Reactions encode all status: hourglass = pending
    # (queued or running), check = done. No text messages are posted —
    # those would clutter the channel with bot chatter and confuse the
    # "latest message tells you cc state" UX.
    try:
        client.reactions_add(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
    except Exception as e:
        log.warning("could not add ack reaction: %s", e)

    # If the session is currently busy (a turn is mid-flight from terminal/
    # Claudian or a previous queued resume), queue and let the drain loop
    # pick it up after Stop fires. Reaction stays as :hourglass: until done.
    if state.get("busy") or sid_has_live_process(sid):
        enqueue(sid, text, channel_id, event_ts)
        return

    def runner() -> None:
        # Per-sid serialization: only one `claude -p --resume <sid>` may
        # run at a time. Prevents two Slack messages from spawning two
        # concurrent CCs that would clobber each other's transcript writes.
        with inject_lock_for(sid):
            _run_inject(state, sid, channel_id, event_ts, text, client)

    def _run_inject(state, sid, channel_id, event_ts, text, client) -> None:
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
                # cwd was deleted/moved since session creation. Fall back to
                # the transcript file's parent's vault root by walking up
                # from transcript_path. This keeps `claude -p --resume`
                # able to find the project's transcript dir even after a
                # repo reorg.
                tp = state.get("transcript_path", "")
                fallback = os.path.expanduser("~/Documents/obsidian-vault")
                if os.path.isdir(fallback):
                    log.warning("cwd %s missing for sid=%s — falling back to %s",
                                cwd, sid[:8], fallback)
                    cwd = fallback
                else:
                    log.error("cwd missing and no fallback for sid=%s", sid[:8])
                    try:
                        client.reactions_remove(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
                        client.reactions_add(channel=channel_id, name="x", timestamp=event_ts)
                    except Exception:
                        pass
                    return

            # File-based marker survives CC's env stripping when it spawns
            # hooks. mirror.sh checks for $STATE_DIR/from-slack/<sid> and
            # skips both the user-prompt mirror (xzixuan message is already
            # in the channel) and the SessionEnd archive (resume's
            # SessionEnd is not a real exit).
            marker_dir = STATE_DIR / "from-slack"
            marker_dir.mkdir(parents=True, exist_ok=True)
            marker = marker_dir / sid
            marker.touch()
            try:
                result = subprocess.run(
                    ["claude", "-p", "--resume", sid, "--permission-mode", "bypassPermissions", "--output-format", "text", text],
                    capture_output=True,
                    text=True,
                    timeout=600,
                    env=child_env,
                    cwd=cwd,
                )
            finally:
                marker.unlink(missing_ok=True)
            if result.returncode != 0:
                log.error("claude -p exit=%d stderr=%s", result.returncode, result.stderr[:500])
                # No text message — failure shows as :x: reaction instead
                try:
                    client.reactions_remove(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
                    client.reactions_add(channel=channel_id, name="x", timestamp=event_ts)
                except Exception:
                    pass
                return
        except subprocess.TimeoutExpired:
            log.error("claude -p timed out 600s sid=%s", sid[:8])
            try:
                client.reactions_remove(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
                client.reactions_add(channel=channel_id, name="alarm_clock", timestamp=event_ts)
            except Exception:
                pass
            return
        except Exception as e:
            log.error("claude -p exception sid=%s: %s", sid[:8], e)
            try:
                client.reactions_remove(channel=channel_id, name="hourglass_flowing_sand", timestamp=event_ts)
                client.reactions_add(channel=channel_id, name="boom", timestamp=event_ts)
            except Exception:
                pass
            return
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


def list_recently_archived(limit: int = 10) -> list[dict[str, Any]]:
    """State files marked archived but Slack channel still alive (not yet
    swept). Sorted newest-first. Excludes truly-Slack-archived ones (the
    sweeper sets a `slack_archived` flag once it actually archives)."""
    archived: list[dict[str, Any]] = []
    for f in STATE_DIR.glob("*.json"):
        try:
            d = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        if not d.get("archived"):
            continue
        if d.get("slack_archived"):
            continue  # already removed from Slack sidebar
        archived.append(d)
    archived.sort(key=lambda d: d.get("archived_at", ""), reverse=True)
    return archived[:limit]


def _humanize_age(iso: str) -> str:
    """'2h ago' / '3d ago' from an ISO timestamp."""
    if not iso:
        return ""
    try:
        ts = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return ""
    delta = datetime.now(timezone.utc) - ts
    secs = int(delta.total_seconds())
    if secs < 60:
        return f"{secs}s ago"
    if secs < 3600:
        return f"{secs // 60}m ago"
    if secs < 86400:
        return f"{secs // 3600}h ago"
    return f"{secs // 86400}d ago"


def archive_sweeper(grace_days: int = 7) -> None:
    """Hourly: walk state files, find sessions where archived_at is
    older than `grace_days`, and actually archive the Slack channel +
    set `slack_archived` flag. Until then channels stay visible in the
    sidebar so the user can find / reopen them."""
    while True:
        try:
            cutoff = datetime.now(timezone.utc).timestamp() - grace_days * 86400
            for f in STATE_DIR.glob("*.json"):
                try:
                    d = json.loads(f.read_text())
                except json.JSONDecodeError:
                    continue
                if not d.get("archived") or d.get("slack_archived"):
                    continue
                iso = d.get("archived_at", "")
                if not iso:
                    continue
                try:
                    ts = datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    continue
                if ts > cutoff:
                    continue  # still within grace
                ch = d.get("channel_id")
                if not ch:
                    continue
                try:
                    app.client.conversations_archive(channel=ch)
                    log.info("swept (archived) sid=%s channel=%s age=%dd",
                             d.get("session_id", "")[:8], ch,
                             int((datetime.now(timezone.utc).timestamp() - ts) // 86400))
                except Exception as e:
                    msg = str(e)
                    if "already_archived" in msg:
                        pass  # fine, fall through to mark it
                    else:
                        log.warning("sweeper archive failed channel=%s: %s", ch, e)
                        continue
                sid = d.get("session_id", "")
                state_update(sid, lambda s: {**s, "slack_archived": True})
        except Exception as e:
            log.error("archive sweeper iteration crashed: %s", e)
        time.sleep(3600)


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.chmod(0o700)

    # Clear orphan from-slack markers from a previous daemon crash. If
    # there were any cc-resume subprocesses still running when the
    # previous daemon died, they're either dead too (subprocess.run is
    # synchronous; killing the daemon kills them) or finished without
    # the daemon's finally-block running. Either way the marker is
    # stale — leaving it tells mirror.sh to skip mirroring forever.
    marker_dir = STATE_DIR / "from-slack"
    if marker_dir.exists():
        cleared = 0
        for m in marker_dir.iterdir():
            try:
                m.unlink()
                cleared += 1
            except OSError:
                pass
        if cleared:
            log.info("cleared %d orphan from-slack marker(s)", cleared)

    log.info("starting cc-bridge daemon (state=%s)", STATE_DIR)

    # Queue drain loop: dispatch queued Slack messages whenever the
    # destination session goes idle (busy=false flipped by Stop hook).
    threading.Thread(target=queue_drain_loop, daemon=True).start()

    # Archive sweeper: hourly, archive Slack channels for sessions that
    # have been state-archived for > 7 days. Keeps recent channels in
    # the sidebar; cleans out stale ones over time.
    threading.Thread(target=archive_sweeper, daemon=True).start()

    handler = SocketModeHandler(app, get_app_token())
    handler.start()


if __name__ == "__main__":
    main()
