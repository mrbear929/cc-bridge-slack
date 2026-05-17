# cc-bridge-slack

Mirror Claude Code sessions to a per-session private Slack channel in
Bear's Amazon Opus sandbox workspace, so sessions can be monitored from
phone Slack while away from the desk.

## Current capabilities (Phase 1.5)

- **Channel per CC session** — every new `session_id` gets its own private channel
- **Bedrock-titled** — channel renames to a 2-4 word slug from Claude Haiku 4.5
  after the first reply (synchronous; rename completes before assistant
  message lands in Slack)
- **Identity overrides** — user prompts post as **Bear** with corp Slack
  avatar; assistant replies post as **Claude Code** with the bot icon
- **Surface detection** — init message + channel topic identify whether the
  session is `obsidian-claudian`, `obsidian-terminal`, `native-terminal`,
  `iterm`, etc.
- **Auto-archive** — channel archives on `SessionEnd` (CC `/exit`)

## Not yet built (Phase 2)

- DM-driven control (`start cc-bridge` / `stop cc-bridge`)
- DM session monitor (active sessions, WTD/MTD summaries)
- Image / file mirroring from prompts
- Filtering test sessions

These need a long-running daemon (Socket Mode) — not built yet.

## Layout

| File | Purpose |
|---|---|
| `mirror.sh`            | hook handler — `UserPromptSubmit` / `Stop` / `SessionEnd` all route here |
| `title-generator.sh`   | calls Bedrock haiku to slug the channel from first prompt+reply |
| `detect-surface.sh`    | classifies the terminal surface from env + ppid chain |
| `dump-surface.sh`      | one-shot diagnostic for verifying detection in a new surface |
| `install.sh`           | new-machine bootstrap (keychain + env file + hook block instructions) |
| `settings.test.json`   | hook config template — paste into `~/.claude/settings.json` |
| `.env.example`         | non-secret config template |
| `tests/manual-test.md` | manual verification steps |

## Where everything actually lives

| Item | Location | Tracked by git? |
|---|---|---|
| Code (`*.sh`, README, install.sh, .env.example, settings.test.json) | this repo (`dev/tools/cc-bridge-slack/`) | ✅ |
| Bot token (xoxb-...) | macOS Keychain (`security find-generic-password -s cc-bridge-slack -a bot-token -w`) | ❌ |
| Non-secret config | `~/.claude/tools/slack-bridge.env` (mode 600) | ❌ |
| Per-session state | `~/.claude/tools/cc-bridge-state/<sid>.json` | ❌ (transient) |
| Hook configuration | `~/.claude/settings.json` `hooks` block | ❌ (CC config) |
| Run log | `/tmp/cc-mirror-test.log` | ❌ (transient) |

## Setup on a new Mac

```bash
git clone git@github.com:mrbear929/tools.git
cd tools/cc-bridge-slack
./install.sh
# follow the prompts: paste bot token, user id, icon URLs
# then paste the printed hook block into ~/.claude/settings.json
```

That's it. Token goes into Keychain (login keychain — survives reboot, not
auto-synced across Macs unless you re-run `install.sh` and paste the token
again).

## Disable / re-enable

| Goal | Action |
|---|---|
| Soft-disable (keep hooks, stop posting) | edit `~/.claude/tools/slack-bridge.env`: `MIRROR_DRY_RUN=1` |
| Hard-disable (remove hooks)             | delete the `"hooks"` block from `~/.claude/settings.json` |
| Re-enable from soft-disable             | set `MIRROR_DRY_RUN=0` in env |
| Rotate token                            | `./install.sh`, choose "overwrite" when prompted |

## Hook scope

- `UserPromptSubmit` → posts your prompt as **Bear**, creating the channel on
  the first prompt of a new session
- `Stop` → posts the assistant reply as **Claude Code**; on the **first**
  reply of a session, synchronously calls Bedrock for a title and renames
  the channel before posting (adds 1-3s to first reply, no delay after)
- `SessionEnd` → posts `_session ended_` and archives the channel

Tool calls (`PreToolUse` / `PostToolUse`) are intentionally NOT mirrored —
would flood the phone with builder-mcp output and similar.

## Security

- Bot token in macOS Keychain (login keychain, not iCloud-sync by default)
- Sandbox workspace is inside Amazon Slack tenant — no external SaaS egress
- Bot only writes to channels it created itself; can't see other channels
- `mirror.sh` swallows all errors and never aborts CC

## Why a sandbox

Bear's Operations workspace requires admin approval to install apps. The
Opus First-Party sandbox program (provisioned via `/provision` in any
Amazon Slack DM) gives a self-administered workspace **inside Amazon Slack
tenant**. Data stays within Amazon — no external SaaS egress.

Reference: [`https://w.amazon.com/bin/view/AmazonUC/SIGNAL/OPUS/SlackApps/FirstPartyApps`](https://w.amazon.com/bin/view/AmazonUC/SIGNAL/OPUS/SlackApps/FirstPartyApps)

## Why this design

- **Hook-driven, not daemon-driven** — Phase 1.5 has no long-running process
  to maintain or restart. Each CC session triggers its own hook calls.
- **State file per session** — survives mid-session reboots; multiple CC
  sessions on the same machine don't collide.
- **Synchronous title rename** — the first reply blocks for 1-3s but lands
  in a properly-named channel. Better UX than seeing a renamed channel name
  3s later in the sidebar.
- **Token in Keychain** — survives reboot, never serialized to disk in
  plaintext, can be inspected/rotated via `security` CLI or Keychain Access.
