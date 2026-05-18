# Using cc-bridge-slack

Once installed (see [INSTALL.md](INSTALL.md)), three places accept
input: the **bot DM**, **session channels**, and **reactions**.

## Bot DM commands

DM the bot directly. All commands are case-insensitive plain text — no
slash prefix (Slack would intercept it client-side).

| Command | Effect |
|---|---|
| `start` / `start cc-bridge` / `resume` | Enable mirroring of new sessions. |
| `stop` / `stop cc-bridge` / `pause` | Pause mirroring. New sessions get no channel; in-flight sessions keep working. |
| `status` / `?` | Reply with current state (enabled / paused). |
| `active` / `list` / `sessions` | List currently running sessions with their channel link, surface, and cwd. |
| anything else | Help text describing the above. |

The DM is also the channel the bridge falls back to when it can't reach
a session channel.

## In-channel commands

Inside a session channel (the per-session private channels the bridge
creates), the daemon recognizes a few one-word commands:

| Command | Effect |
|---|---|
| `exit` / `end` / `archive` | Mark the session ended. The local CC process keeps running (we can't safely kill it remotely), but the channel archives and the state is flagged. Identical to what happens when CC's `SessionEnd` hook fires. |

Anything else typed in a session channel is treated as a **prompt
injection**: the daemon spawns `claude -p --resume <sid>` with the
session's working directory and the message body as the prompt. The
local CC instance for that session must not be busy (the daemon waits
or queues if `busy=true`).

## Reactions

Status of every Slack-side prompt is shown via reactions on **your own
message** (not on bot replies). Three reactions you'll see:

| Reaction | Meaning |
|---|---|
| ⏳ `:hourglass_flowing_sand:` | Daemon received the message; either queued behind a busy session or the inject is in progress. |
| ✅ `:white_check_mark:` | Inject completed. The bot's reply (if any) is posted right after. |
| ❌ `:x:` | Inject failed (e.g. cwd missing, `claude -p` exit ≠ 0). Check `/tmp/cc-bridge-daemon.log` for the cause. |
| ⏰ `:alarm_clock:` | Inject hit the 10-minute timeout. |
| 💥 `:boom:` | Subprocess crashed before producing output. |

The same hourglass→checkmark transition also runs for **locally typed
prompts**: when CC fires `UserPromptSubmit`, `mirror.sh` adds ⏳ to the
mirrored user-identity post; when `Stop` fires (turn complete), it
swaps to ✅. Same status indicator regardless of where the prompt
originated.

## Identifying who said what

Each session channel will see four message sources:

| Author | What it means |
|---|---|
| your real Slack profile | You typed it directly into Slack from any client. |
| `USER_DISPLAY_NAME` (configured in env file) with your avatar | Mirrored from the local CC session — you typed this in terminal/Claudian. |
| `Claude Code` with the bot icon | Reply from the model. |
| the bot itself (`cc-bridge`) | System messages: channel created, archived, topic set, file-uploaded notice. |

The latest message's author is the most reliable busy-state indicator:
if the last message is from `Claude Code`, the session is idle and
ready for input. If the last message is from any user identity (yours
or the mirrored override), CC is still chewing.

## Off-the-desk workflow

The intended flow when you walk away from your Mac:

1. Local CC (terminal or Claudian) is sitting idle. Walk away.
2. Open Slack on phone, find the session channel (or just tap any
   recent unread).
3. Type a follow-up message. ⏳ appears on it.
4. Daemon spawns a `claude -p --resume` subprocess on the Mac. The
   local CC's transcript file gets a new turn appended.
5. Reply mirrors back into the channel as `Claude Code`. ⏳ → ✅.
6. Walk back to the Mac later. In CC, run `/resume` (or simply send a
   new prompt) to pick up the transcript with the new turns merged in.

Two important caveats:

- **Bypass-permission injection.** The daemon spawns CC with
  `--permission-mode bypassPermissions`. Anything CC decides to do
  (shell commands, file edits, network) runs without asking. The
  user-id allowlist (`SLACK_USER_ID` in the env file) is what stops
  someone else's Slack messages from triggering injects. Audit it
  before adding any other user to the workspace.
- **Don't inject into a busy session.** If you send a message to a
  channel whose CC instance is mid-turn, the daemon queues it and
  drains when `Stop` fires. If you send while the local user is also
  typing into the same session at the same time, you get a queue
  ordering surprise — the queued message lands after whatever finishes
  first. In practice this only happens if you're walking back to the
  desk while the bridge is still draining.

## Troubleshooting

See the bottom of [INSTALL.md](INSTALL.md) for the symptom-→-cause
table. Logs:

- `/tmp/cc-mirror-test.log` — every CC hook fire
- `/tmp/cc-bridge-daemon.log` — daemon lifecycle, reply route, errors
- `/tmp/cc-bridge-daemon.stderr.log` — uncaught exceptions
