# cc-bridge-slack

Bidirectional bridge between Claude Code and Slack. Mirrors every CC
session (terminal or Obsidian Claudian) to its own private Slack
channel, and routes Slack messages back into the session via
`claude -p --resume <sid>`.

## What it does

- **Channel per session.** Every new CC `session_id` gets a private
  Slack channel. The channel name matches the title shown in Claudian's
  sidebar (terminal sessions get a Bedrock-generated equivalent).
- **Mirror.** User prompts post as the user identity (corp avatar);
  Claude's replies post as "Claude Code" (bot avatar).
- **Reply.** Type any message in the channel and it's injected into the
  matching CC session as a new prompt. CC's reply mirrors back through
  the same hook path. The `bypassPermissions` flag on the inject is
  what lets remote turns commit + push code, run shell commands, etc.
- **Queue.** If the local CC instance is mid-turn when a Slack message
  arrives, the message is queued and replays as soon as the in-flight
  turn finishes (signaled by `Stop` hook setting `busy=false`).
- **Auto-archive.** `SessionEnd` hook (terminal `/exit`, Claudian close)
  archives the channel. Reopening the session auto-unarchives. Plain
  `exit` / `end` / `archive` typed in the channel also archives.
- **Image upload.** Pasted screenshots in CC are extracted from the
  transcript JSONL and uploaded to the channel as the user identity
  via `files.upload_v2` + permalink unfurl.
- **AskUserQuestion mirror.** When CC raises a tool-call question, the
  question + options post into the channel so the phone-side viewer
  knows what's blocked. Answers are still typed locally (CC has no API
  to inject answers into a running AskUserQuestion).
- **Status by reaction.** Slack-side messages get `:hourglass:` while
  the inject runs, `:white_check_mark:` on success, `:x:`/`:alarm_clock:`
  on failure.

## Architecture

```
                         ┌─────────────────┐
                         │  Slack Bot App  │
                         └────────┬────────┘
                                  │ Socket Mode (outbound WS)
                                  │
                         ┌────────▼────────┐
                         │   daemon (Py)   │  ~/Library/Application Support/cc-bridge-daemon
                         │   slack_bolt    │  launchd-managed; pid in launchctl
                         └────────┬────────┘
                                  │ subprocess.run("claude -p --resume <sid>")
                                  │ + writes from-slack/<sid> marker
                                  │
                         ┌────────▼────────┐
                         │  Claude Code    │  ← also runs natively in terminal/Claudian
                         │   (CLI / SDK)   │
                         └────────┬────────┘
                                  │ hook events (UserPromptSubmit, Stop, SessionEnd, …)
                                  │
                         ┌────────▼────────┐
                         │   mirror.sh     │  Slack post / channel rename / archive
                         └────────┬────────┘
                                  │ chat.postMessage / files.upload / conversations.*
                                  ▼
                         ┌─────────────────┐
                         │  Slack channel  │
                         │  (per session)  │
                         └─────────────────┘
```

### State

Single source of truth per session:

```
~/.claude/tools/cc-bridge-state/<sid>.json
{
  "session_id": "abc123…",
  "channel_id": "C0…",
  "channel_name": "consolidate-ideas-checkbox",
  "title": "Consolidate dev/ideas files into one MD",
  "cwd": "/path/to/project",
  "surface": "obsidian-claudian|obsidian-terminal|native-terminal|iterm|…",
  "device": "host-shortname",
  "transcript_path": "/path/to/projects/.../<sid>.jsonl",
  "first_prompt": "...",
  "first_reply": "...",
  "busy": false,
  "renamed": true,
  "archived": false
}
```

Concurrent writes (mirror.sh hook fires + daemon channel-exit + drain
loop) coordinate via a per-sid mkdir-based mutex at
`~/.claude/tools/cc-bridge-state/.lock-<sid>`. Stale locks are cleared
after 10 s.

Queue:

```
~/.claude/tools/cc-bridge-state/queue/<sid>.jsonl   ← appended by daemon
                              from-slack/<sid>      ← marker dropped by daemon
                                                      around each inject so
                                                      mirror.sh can recognize
                                                      synthetic UserPromptSubmit
```

### Tokens

| Token | Where | Why |
|---|---|---|
| Bot User OAuth (`xoxb-`) | macOS Keychain (`security` CLI, service `cc-bridge-slack`, account `bot-token`) | Never written to disk in plaintext |
| App-level (`xapp-`) | `~/.claude/tools/slack-bridge-app.token` (mode 600) | launchd needs a path to read; copy from password manager |

### Surface detection

`detect-surface.sh` classifies the host using:

1. `__CFBundleIdentifier` env (set by macOS for any subprocess of a GUI
   app — Obsidian, Terminal.app, iTerm, Warp, VS Code, Cursor)
2. `CLAUDE_CODE_ENTRYPOINT` env (`sdk-ts` = Claudian, `cli` = headless)
3. ppid chain walk (fallback when env signals are missing)

### Title source

For Obsidian Claudian sessions, `title-generator.sh` reads
`<vault>/.claudian/sessions/conv-*.meta.json` and reuses the title
Claudian itself generated. For other surfaces it falls back to a
single Bedrock Haiku 4.5 call asking for a Claudian-style imperative
phrase. Either way the result populates:

- channel **name** (slug, ≤ 70 chars, `-2` / `-3` suffix on collision)
- channel **topic** (full sentence + cwd)
- state **title** field

Title generation runs in the background after the first reply lands;
it does not delay Slack output.

### Mirror→Slack→Mirror loop avoidance

Without care, each Slack-driven inject would: (1) hit `mirror.sh user`
hook → mirror your prompt as user identity (duplicating the message
already posted by you typing it), (2) hit `SessionEnd` when the
`claude -p` subprocess finishes → archive the channel mid-conversation.

Both are skipped via the `from-slack/<sid>` marker file, dropped by the
daemon before `subprocess.run` and unlinked in `finally`. The marker
survives CC's env-stripping when it spawns hooks (env vars don't).

## Layout

```
cc-bridge-slack/
├── README.md                           ← repo intro + pointers
├── docs/
│   ├── README.md                       ← architecture (this file)
│   ├── INSTALL.md                      ← new-machine bootstrap
│   └── USAGE.md                        ← DM commands, channel commands, reactions
├── install.sh                          ← interactive installer
├── settings.test.json                  ← hook block to merge into ~/.claude/settings.json
├── .env.example                        ← non-secret config template
├── mirror.sh                           ← CC hook handler (bash)
├── title-generator.sh                  ← async channel-rename worker
├── detect-surface.sh                   ← terminal-surface classifier
├── dump-surface.sh                     ← diagnostic: prints what detect-surface sees
├── hook-dump.sh                        ← diagnostic: dumps every hook payload
├── daemon/
│   ├── main.py                         ← Socket Mode listener
│   ├── pyproject.toml + uv.lock        ← uv-managed deps
│   ├── run.sh                          ← launchd entry (loads token, exec uv run)
│   ├── sync-to-launchd.sh              ← copy source → launchd install dir
│   └── launchd/com.cc-bridge.daemon.plist ← LaunchAgent definition
└── tests/manual-test.md                ← verification checklist
```

## Disable / pause

| Goal | Action |
|---|---|
| Pause new sessions (existing keep mirroring) | DM the bot: `stop` |
| Resume | DM: `start` |
| Soft-disable everything | edit `~/.claude/tools/slack-bridge.env` → `MIRROR_DRY_RUN=1` |
| Hard-disable | delete the `"hooks"` block from `~/.claude/settings.json` |
| Stop daemon | `launchctl bootout gui/$(id -u)/com.cc-bridge.daemon` |
| Restart daemon | `launchctl kickstart -k gui/$(id -u)/com.cc-bridge.daemon` |

## Logs

```
/tmp/cc-mirror-test.log         ← every hook fire (mirror.sh)
/tmp/cc-bridge-daemon.log       ← daemon lifecycle + reply route
/tmp/cc-bridge-daemon.stderr.log ← uncaught daemon exceptions
```

## Security model

This bridge runs `claude -p --permission-mode bypassPermissions`. That
means a Slack message routed in can drive arbitrary tool calls in the
session's working directory — file edits, shell commands, network
requests. Two mitigations are in place:

1. **User-id allowlist.** The daemon refuses any Slack event whose
   `user` field doesn't match `SLACK_USER_ID` from the env file. If
   the bot is ever added to a shared channel and someone else types,
   the message is dropped with a `WARNING` log line.
2. **Sandbox workspace.** The bot is installed in an Amazon Opus
   first-party sandbox (provisioned via `/provision` in any internal
   Slack DM). The workspace is single-user and inside the corporate
   tenant — no external SaaS egress, no third-party Slack admins.

If you fork this for a different workspace, audit both before enabling
reply routing.

## Updating the daemon

Source of truth lives in this git repo. The launchd-managed daemon
runs from `~/Library/Application Support/cc-bridge-daemon/` because
launchd can't read files under `~/Documents` (macOS privacy). Sync
after edits:

```bash
./daemon/sync-to-launchd.sh
```

This copies the four code files (main.py, run.sh, pyproject.toml,
uv.lock), `uv sync`s the venv, and kicks the launchd service.

`mirror.sh` and the helper bash scripts are read directly from the git
repo by CC hooks — no sync needed for those.
