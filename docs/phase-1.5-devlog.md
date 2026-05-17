# cc-bridge-slack — Phase 1.5 development log

Built 2026-05-17 in one ~3-hour session with Claudian. Captures the
actual path taken (with mistakes) for future reference and for handing
off Phase 2.

## Goal

Bear is an EM whose CC sessions run on his Amazon-managed Mac. He
wanted to monitor sessions from his phone while away from the desk —
without giving up Amazon-internal data sovereignty.

## What Phase 1.5 ended up being

A hook-driven bridge that mirrors each CC session as its own private
Slack channel inside Bear's Opus sandbox workspace. Per-session, fully
automatic — no daemon, no long-running process.

| Capability | How |
|---|---|
| Channel per session | UserPromptSubmit creates a private channel keyed by `session_id` |
| Bedrock-titled rename | After the first reply, `claude-haiku-4.5` generates a 2-4 word slug; channel renames before the reply lands in Slack |
| User identity = Bear | `chat.postMessage` with `username` + `icon_url` override (corp Slack avatar) |
| Assistant identity = Claude Code | Same override, but uses the cc-bridge bot's icon URL |
| Surface detection | `__CFBundleIdentifier` env var + `CLAUDE_CODE_ENTRYPOINT` + ppid chain |
| Init message | Multi-line "Session start" card with started/surface/device/cwd/sid |
| Session archive | SessionEnd hook calls `conversations.archive` |
| Sub-session noise filter | If user prompt is a CC-internal title-gen / summary, skip channel creation entirely |
| GFM → Slack mrkdwn | Python regex pipeline strips `**`, `##`, `[](url)`, `~~~~`, protecting code blocks |
| Image upload | Background process: parses base64 images out of transcript JSONL, uploads via `files.upload_v2`, posts permalink as Bear with hidden link wrapping |

## Architecture

```
Claude Code session                  ┌───────────────────────────────┐
  │                                  │  /tmp/cc-mirror-test.log      │
  │ UserPromptSubmit hook            │  (run log)                    │
  │ Stop hook                        └───────────────────────────────┘
  │ SessionEnd hook                                  ▲
  │                                                  │
  ▼                                                  │
mirror.sh ─┐                                         │
           ├──▶ post text msg as Bear/Claude Code ──▶├──▶ slack.com/api
           │     (chat.postMessage, mrkdwn=true)     │
           │                                         │
           ├──▶ ensure_channel()                     │
           │     create / set topic / invite Bear ──▶│
           │                                         │
           ├──▶ title-generator.sh (synchronous)     │
           │     Bedrock haiku 4.5 → rename ────────▶│
           │                                         │
           └──▶ upload_user_images() (BACKGROUND)    │
                 transcript JSONL parse              │
                 base64 → PNG → files.upload_v2 ────▶│
                 chat.postMessage as Bear            │

state file ~/.claude/tools/cc-bridge-state/<sid>.json
  channel_id, channel_name, surface, cwd, first_prompt, first_reply, renamed
```

## Where everything lives (final, not vault/tools/!)

| Item | Location | git-tracked? |
|---|---|---|
| Code (`mirror.sh`, helpers, README) | `dev/tools/cc-bridge-slack/` | ✅ (own repo, github.com/mrbear929/tools) |
| Bot token (xoxb-) | macOS Keychain (login keychain) | ❌ |
| App-level token (xapp-) | Apple Passwords (iCloud-synced) | ❌ |
| Non-secret config | `~/.claude/tools/slack-bridge.env` (mode 0600) | ❌ |
| Per-session state | `~/.claude/tools/cc-bridge-state/<sid>.json` | ❌ |
| Hook config | `~/.claude/settings.json` `"hooks"` block | ❌ |
| Run log | `/tmp/cc-mirror-test.log` | ❌ |

## Path the conversation took (mistakes & learnings)

### 1. False start: vault/tools/ vs dev/tools/
Claudian created the scaffold under `vault/tools/cc-bridge-slack/`
because `CLAUDE.md` mentioned `tools/`. Bear actually keeps tools at
`dev/tools/` (already a separate git repo). Required `git mv` of the
whole tree + path updates in `~/.claude/settings.json` + dump-surface
script + .env.example + README. Lesson: read existing structure before
trusting CLAUDE.md.

### 2. Wrong settings file
Hooks were initially written to `~/.claude/settings.local.json`. CC
**doesn't read hooks from settings.local.json** — only the main
`settings.json`. Wasted 30 minutes debugging "why doesn't the hook
fire". Confirmed by running `claude -p "say hi"` with `--include-hook-events`
and seeing no hook events emitted.

### 3. macOS doesn't have `tac`
First implementation of "extract last assistant message from transcript"
used `tac transcript | while read line ...`. Worked silently as a no-op
on macOS where `tac` doesn't exist. Replaced with `jq -rs 'map(select)
| last'`.

### 4. Title-rename heuristic was a dead end
First attempt: detect CC's own internal title-gen (a short Stop reply
right after the real Stop) and use it as the channel name. This was
wrong twice over:
- Claudian SDK doesn't fire that internal title-gen at all
- Even when terminal CC fires it, the heuristic falsely matched short
  legitimate replies like "yes sir"

Replaced with our own Bedrock haiku call. Bear's `AWS_PROFILE=claude-code-DO-NOT-DELETE`
already had Bedrock access, so we just pipe `first_prompt + first_reply`
to `claude-haiku-4-5-20251001-v1:0` and ask for a kebab-case slug.

### 5. Race condition: synchronous title rename
Bear wanted "channel name correct **at the moment** the first reply
appears in Slack" — not 1-3s later. So the Stop handler now calls
`title-generator.sh` synchronously *before* posting the assistant text.
First reply takes 1-3s longer; subsequent replies have no overhead.

### 6. Sub-session pollution
CC fires UserPromptSubmit/Stop for internal sub-sessions (its own title
gen, todo regen, summarization). The **user** prompts of these were
caught by `is_user_noise`, but **Stop** still fired and our code
created a brand-new channel for the sub-session. Result: phantom
channels with one cryptic short message that immediately archived.

Fix: if a session has no state file (= we never ran ensure_channel for
it), Stop and SessionEnd no-op. Sub-sessions never get state files
because the user noise filter prevented ensure_channel from running,
so they're invisible.

### 7. macOS `__CFBundleIdentifier` is the surface superpower
ppid-chain walking was unreliable: hook process is several layers deep
from the host app, ppid chain sometimes breaks on PTY boundaries, and
ps `comm` columns are inconsistent. macOS sets `__CFBundleIdentifier`
as an env var on every subprocess spawned from a GUI app, and it
**survives** subprocess inheritance.

```
md.obsidian + entrypoint=sdk-ts → obsidian-claudian
md.obsidian + entrypoint=cli   → obsidian-terminal
com.apple.Terminal             → native-terminal
com.googlecode.iterm2          → iterm
dev.warp.Warp-Stable           → warp
```

`CLAUDE_CODE_ENTRYPOINT` env var (set by CC at boot) was the second
key piece — more reliable than reading the transcript JSONL because
the transcript's first line has `entrypoint:null` (queue-operation
record) and only later records have the real value.

### 8. Slack `mrkdwn` ≠ GitHub markdown
Lots of subtle differences. The big offenders:
- `**bold**` (GFM) is `*bold*` in mrkdwn
- `*italic*` (GFM) is `_italic_` in mrkdwn
- `[text](url)` (GFM) is `<url|text>` in mrkdwn
- `## H` headings render literally in mrkdwn — convert to `*H*` (bold) on its own line
- `~~strike~~` is `~strike~` in mrkdwn

Code blocks (triple-backtick and single-backtick) render the same in
both, so we placeholder-out their content before regex transforms and
restore at the end. Avoids "**foo**" inside a code sample being mangled
to "*foo*".

User prompts pass through unchanged (Bear doesn't write GFM in chat).

### 9. Image upload — three iterations
**v1**: parse "latest user message with images" from transcript, upload
sync. Worked on synthetic test, but in real Claudian:
**v2 problem**: prompt #2's image upload posted prompt #1's image,
because Claudian's transcript flush lags hook fire by 30+ seconds.
"Latest" was wrong by one turn.

**v3**: anchor each upload to the prompt's exact text (first 80 chars
substring match). Now correctly associated, but `gave up waiting for
transcript anchor` after 6s of retries — Claudian's flush is slow.

**v4 (final)**: keep the anchor matching, but fork upload as a detached
background process with up to 90 seconds of retries. Prompt text in
Slack is immediate; image arrives "soon enough" — usually within 10-30s
of Claudian's first turn finishing.

### 10. Image author override
Default Slack behavior: bot uploads file → system message "cc-bridge
uploaded a file" appears in the channel. No way to override author of
a file message.

Worked around by:
1. Calling `files.completeUploadExternal` **without** `channel_id` so
   no auto-share message is posted
2. Getting the file's `permalink` from the response
3. Posting a `chat.postMessage` as Bear with the permalink wrapped as
   `<permalink| >` (empty visible label) so the URL itself is hidden
   but Slack unfurls the file underneath

Slack still shows `cc-bridge | image-1.png` in tiny grey text inside
the unfurl card itself — that's the file uploader's identity, no API
override exists. Bear accepted this.

## Token storage

| Token | Where | Why |
|---|---|---|
| Bot User OAuth (`xoxb-`) | macOS Keychain login keychain | Used by every script invocation; `security find-generic-password` is fast |
| App-level (`xapp-`) | Apple Passwords (iCloud-synced) | Phase 2 daemon will need it; iCloud sync gets it to Bear's other Mac |

`security` CLI **doesn't** put items in iCloud Keychain by default —
they live in `login.keychain` which is local-only. Phase 2 daemon will
either prompt user to copy from Apple Passwords or run a small Python
helper using the `keyring` library which can target the iCloud item.

## Hook configuration

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{
      "type": "command",
      "command": "/Users/xzixuan/Documents/obsidian-vault/dev/tools/cc-bridge-slack/mirror.sh user"
    }]}],
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "/Users/xzixuan/Documents/obsidian-vault/dev/tools/cc-bridge-slack/mirror.sh assistant"
    }]}],
    "SessionEnd": [{ "hooks": [{
      "type": "command",
      "command": "/Users/xzixuan/Documents/obsidian-vault/dev/tools/cc-bridge-slack/mirror.sh end"
    }]}]
  }
}
```

## Sandbox provisioning

Bear's Operations workspace requires admin approval for any Slack app
install. The Opus First-Party Apps program provides a self-administered
sandbox: type `/provision` in any Amazon Slack DM, fill the form,
Slackbot DMs back a ready workspace. Bear is admin so app install
auto-approves.

Reference:
[`https://w.amazon.com/bin/view/AmazonUC/SIGNAL/OPUS/SlackApps/FirstPartyApps`](https://w.amazon.com/bin/view/AmazonUC/SIGNAL/OPUS/SlackApps/FirstPartyApps)

Workspace: `mrbear-ccbrid-1401342.slack.com` (sandbox).

## Phase 2 inputs (carry forward to next session)

- `xapp-` token in Apple Passwords ready
- `xoxb-` token in Keychain ready
- All scopes already granted: `chat:write`, `chat:write.customize`,
  `groups:write`, `groups:write.invites`, `groups:write.topic`,
  `channels:manage`, `files:write`, `im:read`, `im:write`,
  `im:history`, `users:read`, `groups:history`, `groups:read`, `files:read`
- App is **already installed** with Socket Mode enabled
- `connections:write` scope on app token

Phase 2 design points already captured:
- Daemon = Python + `slack_bolt` (Socket Mode), listens for DMs to bot
- DM commands: `start cc-bridge` / `stop cc-bridge` / `monitor day` etc.
- `claude -p --resume <sid>` to inject inbound DM as a new prompt into
  an existing CC session
- Persisted via SQLite at `~/.claude/tools/cc-bridge-state/daemon.db`
- launchd-managed; survives reboot

Open question for Phase 2:
- AskUserQuestion mirroring → at minimum, mirror the question text to
  the channel as a Notification hook (Phase 1.5 can do this); answering
  back from Slack needs the daemon

## Outstanding (post-Phase 1.5)

- DM control (start/stop) — needs daemon
- DM monitor (active sessions, WTD/MTD) — needs daemon
- AskUserQuestion mirror — Phase 1.5 capable, not yet built
- Test session noise filter — pure mirror.sh logic, not yet built

## How to install on a fresh Mac

```bash
git clone git@github.com:mrbear929/tools.git
cd tools/cc-bridge-slack
./install.sh
# Follow prompts: paste bot token, user id, icon URLs.
# Then paste the printed hook block into ~/.claude/settings.json.
```

That's it. xapp- token gets re-pulled from Apple Passwords manually
when Phase 2 daemon is set up.
