# cc-bridge-slack — development log

A holistic record of the system. Captures the **current architecture**,
the **known bugs / open issues**, and the **lessons** learned along the
way. Forget the "phases" — this is the system as it stands.

## What this is

A bridge between Claude Code and Slack that:

1. **Mirrors** every CC session (terminal or Obsidian Claudian) into a
   per-session private Slack channel, with the user's prompts posted
   under one identity and Claude's replies under another.
2. **Routes** Slack-side replies back into the matching CC session via
   `claude -p --resume <sid>`, so the user can continue a conversation
   from a phone or a second Mac without being at the original keyboard.

The bridge runs in two pieces:

- **`mirror.sh`** (bash) — a Claude Code hook that posts to Slack on
  every `UserPromptSubmit`, `Stop`, `SessionEnd`, and `PreToolUse` /
  `PostToolUse` for `AskUserQuestion`. Runs once per hook fire.
- **A Python daemon** (`daemon/main.py`) — a long-running Slack Bolt
  Socket Mode listener that handles inbound Slack events: DM
  commands (`start` / `stop` / `active` / `status`), in-channel exit
  commands (`exit` / `end` / `archive`), and reply routing into CC.

State lives in three places:

- **`~/.claude/tools/cc-bridge-state/<sid>.json`** — single dict per
  session: channel id, name, surface, cwd, transcript path, busy flag,
  archived flag, pending hourglass reaction ts, etc. Written by both
  `mirror.sh` and the daemon under a per-sid `mkdir`-mutex.
- **`~/.claude/tools/cc-bridge-state/queue/<sid>.jsonl`** — daemon's
  queue file for Slack messages that arrived while the session was
  busy. Drained when `Stop` fires.
- **`~/.claude/tools/cc-bridge-state/from-slack/<sid>`** — empty
  marker file dropped by the daemon while a `claude -p --resume`
  subprocess is running. `mirror.sh` checks for it to skip mirroring
  the synthetic `UserPromptSubmit` (the user's Slack message is
  already in the channel) and to skip archiving on the synthetic
  `SessionEnd` that fires when `claude -p` exits. Cleared in `finally`,
  and on daemon startup as a belt-and-suspenders for crashes.

## Architecture diagram

```
                            Slack Bot App
                                  │
                                  │ Socket Mode (outbound WS, no public endpoint)
                                  │
                          ┌───────▼────────┐
                          │   daemon (py)  │  launchd-managed, restart on crash
                          │   slack_bolt   │  reads xoxb from Keychain
                          └───┬────┬───┬───┘
                              │    │   │
            on inbound DM ────┘    │   └──── on inbound channel msg
                                   │
                       in-channel exit cmd
                                   │
                              spawn `claude -p --resume <sid>`
                              (after marker drop, after live-process check,
                               with sid_has_live_process guard so the local
                               session can't be raced)
                                   │
                          ┌────────▼────────┐
                          │  Claude Code    │
                          │  (CLI / SDK)    │  also runs natively in
                          └────────┬────────┘  terminal / Obsidian Claudian
                                   │
                            hook events
                                   │
                          ┌────────▼────────┐
                          │   mirror.sh     │  posts via chat.postMessage
                          │                 │  uploads images, manages archive,
                          │                 │  swaps reactions on user's own msg
                          └────────┬────────┘
                                   │
                          ┌────────▼────────┐
                          │  Slack channel  │
                          │  per session    │
                          └─────────────────┘
```

## Identity & UX choices

- **User prompts** post under `USER_DISPLAY_NAME` (configured per
  install) with `USER_ICON_URL` as the avatar. Reads as if "you" sent
  it from CC.
- **Claude's replies** post as `Claude Code` with the bot's app icon
  (Anthropic-style logo). Reads as the model speaking.
- **Slack-side messages** keep their actual sender (your real Slack
  profile). The latest-message author is the most reliable busy
  signal: if the last message in a channel is `Claude Code`, the
  session is idle.
- **Status reactions** on the user's own Slack message:
  - ⏳ `:hourglass_flowing_sand:` — daemon got it; queued or running.
  - ✅ `:white_check_mark:` — turn complete.
  - ❌ `:x:` — inject failed (cwd missing, claude -p exit != 0).
  - ⏰ `:alarm_clock:` — claude -p timed out (10 min).
  - 💥 `:boom:` — subprocess crashed before output.
  - ❓ `:grey_question:` — session hit AskUserQuestion (needs local
    interaction; see "AskUserQuestion limitation" below).

## Channel naming

A new session gets a placeholder channel `session-<sid8>` immediately
on the first `UserPromptSubmit`. Then, **asynchronously** after the
first reply lands, `title-generator.sh` runs in the background:

1. If the session is `obsidian-claudian` surface, it polls
   `<vault>/.claudian/sessions/conv-*.meta.json` for up to 30s
   waiting for Claudian's own title-generation to finish, then
   reuses that title verbatim. Zero Bedrock calls, perfect parity
   with what the user sees in Claudian's sidebar.
2. Otherwise (terminal CC, iTerm, native Terminal, etc.), one
   Bedrock Haiku 4.5 call is made asking for a Claudian-style
   imperative phrase. ~$0.001 per session.

The result fills in:
- channel **name** — slug (lowercase, `-` separated, ≤ 70 chars,
  `-2` / `-3` suffix on collision)
- channel **topic** — the full sentence + cwd
- state **title** field

## Key invariants and the bugs that broke them

The system has been through a lot of iteration. Things that **must
hold** for it to work, listed with the bugs that violated them:

### Invariant 1: from-slack markers must always be cleaned up

Marker files signal "the next mirror.sh hook fire is from a
daemon-spawned cc-resume, not a real local turn." If a marker
**leaks** (daemon crashes mid-spawn, kickstart kills subprocess
before `finally` runs, etc.), every subsequent local hook fire is
mistakenly skipped — the session goes silent and looks stuck even
though the local CC is fine.

**Defenses now in place**:
- `try / finally` around every spawn (mirror or daemon path).
- Daemon `main()` clears `from-slack/*` on startup.
- Markers are 0-byte and named after sid; trivial to inspect /
  delete by hand.

**Open weakness**: if the user `kickstart -k`s the daemon while a
slow `claude -p --resume` is running, the launchd kill-tree behavior
may take down the subprocess _after_ the daemon's `finally` had a
chance — but the user's mental model is still "I just restarted, it
should be fine."

### Invariant 2: state file writes must be serialized per sid

`mirror.sh` and the daemon both update `<sid>.json`. Without a lock,
the read-modify-write-then-mv-temp dance can drop changes.

**Defense**: per-sid `mkdir`-as-mutex at
`<state>/.lock-<sid>`. Stale-lock cleanup at 10s. Both processes
share the same lock dir, so they coordinate. macOS lacks `flock`
which is why `mkdir` is the chosen primitive.

### Invariant 3: don't race the local CC

If the user has CC actively running for sid X locally, daemon must
not spawn its own `claude -p --resume X`. Two CC processes writing
the same transcript = corruption.

**Defenses**:
- `state.busy` flag set by `UserPromptSubmit`, cleared by `Stop`.
- `sid_has_live_process(sid)` walks `ps` looking for any cc command
  containing the sid that's *not* in the daemon's process group.
- If either says active → the message is **queued** (file in
  `queue/<sid>.jsonl`). Drainer wakes when `state.busy` flips false.

**Open issue**: Claudian SDK occasionally fires `Stop` for what
looks like a tool-call boundary while still mid-turn, racing
`busy=false` against `sid_has_live_process=true`. The fallback
`sid_has_live_process` catches this — but this is exactly why both
checks exist.

### Invariant 4: SessionEnd must reach mirror.sh

If `SessionEnd` doesn't fire (or fires to a hook that crashes),
state stays `archived: false` and channels accumulate forever.

**Real bugs that broke this**:
- Initial naive code archived on _every_ `SessionEnd`, including
  Claudian's spurious sub-session SessionEnds, which destroyed the
  user's main channel mid-conversation. Fixed: skip when no state
  file exists (sub-sessions don't create one because their `user`
  prompt was filtered as cc-internal noise).
- `state_lock` had a missing `import time` after a refactor —
  every `state.busy = false` in the daemon's `channel-exit`
  handler crashed silently. Fixed.
- Daemon kickstart killed an in-flight `claude -p --resume`,
  marker leaked, every subsequent SessionEnd looked like a
  from-slack injection. Fixed via the orphan-marker sweeper at
  daemon startup.

## Known sharp edges (still rough)

These are not "bugs to fix" — they are inherent constraints we
chose to live with rather than absorb the cost of fixing:

### 1. AskUserQuestion blocks the local CC instance

When the model raises `AskUserQuestion`, the local CC implementation
suspends the turn waiting for a UI gesture (terminal keystroke or
Claudian button click). Slack remote replies cannot deliver that
gesture; CC has no public IPC for "answer this pending tool call
externally." The daemon will still spawn `claude -p --resume` in
response to the user's Slack reply, but that runs as a **fork** off
the same transcript: the daemon's CC writes a new turn that is
visually present in Slack and on disk, but the local Claudian
in-memory state stays stuck on the original AskUserQuestion. Reload
Claudian (close and reopen the conversation) to merge.

**Workaround in place**: vault `CLAUDE.md` instructs CC to ask
questions as plain text rather than calling `AskUserQuestion`. CC
mostly complies but not always — when it does call the tool, the ❓
reaction shows up on the user's Slack prompt and they'll know to
resolve at the desk.

### 2. The current Claudian conversation can't reply-route to itself

If you type into the channel that mirrors the **conversation you are
currently having with Claudian**, the daemon detects the live
process and queues the message. The queue drains only when that
session goes idle (i.e. you finish your current turn locally). This
is correct behavior — but it can feel like Slack is "stuck." The ⏳
will sit until Claudian's next `Stop` fires.

### 3. Slack Socket Mode WebSocket flaps

Periodic `BrokenPipeError` / `ConnectionResetError` from slack_bolt
during long idle stretches. The library reconnects automatically
within seconds, but events fired during the gap are lost.

### 4. Reply routing creates a transcript fork

`claude -p --resume <sid>` does not splice into the main thread —
its turn is appended at the end of the transcript file but the
parent_uuid chain points at a sub-tree. Local Claudian, on reload,
follows the main thread by parent_uuid and won't see fork turns.
This is OK for the "you've left the desk, don't plan to come back to
this conversation" workflow; it's a problem for "I want to push some
work from my phone but resume editing locally later." Hardest to fix
of the open issues.

### 5. cwd may be stale in old state files

Sessions created before a directory move (e.g. `vault/tools/` →
`vault/dev/tools/`) carry the old path. Daemon now falls back to
`~/Documents/obsidian-vault` if the recorded cwd is missing, but
that's a heuristic. A proper fix would be to refresh cwd from the
hook payload on every `UserPromptSubmit` — the payload always carries
the current cwd.

## Lessons learned

- **macOS launchd cannot read files under `~/Documents`**. The
  daemon source-of-truth lives in the git repo at `dev/tools/`, but
  the live install is mirrored to
  `~/Library/Application Support/cc-bridge-daemon/`. A
  `sync-to-launchd.sh` script keeps them in sync.
- **CC strips most env vars when spawning hooks.** Marker files are
  the only reliable way to communicate "this hook fire originated
  from my own subprocess." Env vars round-trip back to the daemon's
  env but not to the hook's.
- **Claudian's title generation is async and writes to
  `<vault>/.claudian/sessions/conv-*.meta.json`** — once we found
  this, we stopped paying for Bedrock title calls on Claudian
  sessions. Unfortunately the file format is plugin-internal and
  could change.
- **Slack mrkdwn ≠ GitHub markdown.** `**bold**` doesn't render —
  it's `*bold*`. Headings render literally — convert `## H` to
  `*H*` on its own line. Links are `<url|text>` not `[text](url)`.
  The converter respects code blocks (skips conversion inside
  triple-backtick or single-backtick spans).

## Where everything lives

| Item | Path | Why there |
|---|---|---|
| Code source of truth | `dev/tools/cc-bridge-slack/` | git repo, version-controlled |
| Live daemon install | `~/Library/Application Support/cc-bridge-daemon/` | launchd can read from here, can't read `~/Documents` |
| Hook config | `~/.claude/settings.json` `"hooks"` block | CC reads at session start |
| Bot token (xoxb) | macOS Keychain (service `cc-bridge-slack`, account `bot-token`) | never serialized to disk |
| App-level token (xapp) | `~/.claude/tools/slack-bridge-app.token` (mode 600) | launchd needs a path to read |
| Per-session config | `~/.claude/tools/slack-bridge.env` (mode 600) | non-secret runtime knobs |
| Per-session state | `~/.claude/tools/cc-bridge-state/<sid>.json` | one file per session, locked on write |
| Queue (busy sessions) | `~/.claude/tools/cc-bridge-state/queue/<sid>.jsonl` | drained on Stop hook |
| Active-resume markers | `~/.claude/tools/cc-bridge-state/from-slack/<sid>` | swept on daemon startup |
| Hook log | `/tmp/cc-mirror-test.log` | every mirror.sh fire |
| Daemon log | `/tmp/cc-bridge-daemon.log` | lifecycle + reply route |
| Daemon stderr | `/tmp/cc-bridge-daemon.stderr.log` | uncaught exceptions, slack_bolt connection chatter |

## Next-time-you-pick-this-up checklist

1. Read `docs/PRD.md` for the feature catalog (status, requirements,
   acceptance tests) and the current cycle's phasing.
2. Read this DEVLOG for invariants and known sharp edges.
3. Run `tail -f /tmp/cc-bridge-daemon.log` and
   `tail -f /tmp/cc-mirror-test.log` in two panes.
4. Pick a 🔧 or 📋 item from PRD §6 or investigate one of the sharp
   edges above.
5. Don't change Invariants 1-4 without understanding why they're
   there. Most of the bugs above are violations of those.
