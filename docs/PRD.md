# cc-bridge-slack — PRD

Single source of truth for what cc-bridge-slack is, what it does today, what it ships next, and how each capability is verified. `DEVLOG.md` holds deeper architecture notes and lessons learned; this PRD is the product contract.

Status legend: ✅ shipped · 🔧 in this cycle · 📋 next · ❄️ deferred · ❌ won't do.

---

## 1. Goal

Mirror every Claude Code session to a private Slack channel, and let the same Slack channel (or a DM to the bot) push prompts back into Claude Code. The user must be able to:

1. Walk away from the desk mid-task and watch CC continue from a phone.
2. Reply from Slack to keep CC going without being at the keyboard.
3. Start a brand-new CC session from Slack with no laptop in hand.
4. Find recent and historical sessions in Slack without manual hunting.

Non-goal: sharing CC sessions with anyone else. Single-user-by-design.

## 2. Users & surfaces

- **One user**: Bear (`xzixuan`). The bot enforces `SLACK_USER_ID` allowlist on every inbound event.
- **CC surfaces**: terminal CC, Obsidian Claudian, and any future CC surface that fires the standard hooks (`UserPromptSubmit`, `Stop`, `SessionEnd`, `PreToolUse`, `PostToolUse`).
- **Slack surfaces**: per-session private channels (one per CC `session_id`) and a DM channel with the bot for global control commands.

## 3. Architecture (1 page)

Two processes, three state stores, one private Slack workspace. Full diagram and lessons live in `DEVLOG.md`; this is the abridged map.

```
CC hook fires → mirror.sh (bash, one-shot per hook)
                      ↓
             Slack chat.postMessage / files.upload_v2 / conversations.archive
                      ↑
Slack inbound event → daemon/main.py (python, long-running, launchd)
                      ↓
                spawn `claude -p --resume <sid>` for replies
                spawn `claude -p` (fresh session) for new-session DMs
```

State (all under `~/.claude/tools/cc-bridge-state/`):
- `<sid>.json` — per-session record. Channel id, name, surface, cwd, transcript path, busy, archived, slack_archived, archived_at, pending_user_ts, title.
- `queue/<sid>.jsonl` — Slack messages received while a session was busy.
- `from-slack/<sid>` — empty marker file: tells `mirror.sh` "the next hook fire originated from a daemon-spawned subprocess, skip user-side mirror and skip SessionEnd-driven archive."

Per-sid mutex: `<state>/.lock-<sid>` via `mkdir` (POSIX-atomic, replaces `flock` which macOS lacks). 10s stale-lock cleanup.

---

## 4. Feature catalog

Three top-level capabilities. Each row has a status, a "what it means for me" (plain-language user impact), a "requirement" (what the system must do), and an "acceptance test" (how we verify).

### 1. Slack mirrors every CC session (Claudian + terminal)

| ID | Status | What it means for me | Requirement | Acceptance test |
|---|---|---|---|---|
| 1.1 | ✅ | Whenever I start a session anywhere, a Slack channel appears for it within seconds — I never have to create one manually. | First `UserPromptSubmit` for a new `session_id` creates a private channel `cc-<cwd>-<sid8>`. State file written with `channel_id` before the next hook fires. | New CC session in any cwd → Slack sidebar gets a new private channel within 5s. State file `<sid>.json` contains a non-empty `channel_id`. |
| 1.2 | ✅ | The very first Slack message tells me which session this is, where it's running, and how to find the transcript on my Mac — even if I'm only on my phone. | First post in channel includes Started time, Surface (terminal/Claudian/iTerm/etc), Device, Cwd, full Session UUID, full Transcript path. | Open new channel → first message has all six fields. |
| 1.3 | ✅ | The channel topic at a glance shows me which session/surface/cwd this is, without scrolling. | Topic = `session: <sid> · surface: <surface> · cwd: <path>`. | `conversations.info` returns matching topic. |
| 1.4 | ✅ | I can tell at a glance who said what — my prompts look like me, Claude's replies look like Claude. | User prompts post under `USER_DISPLAY_NAME` + `USER_ICON_URL`. Assistant messages post as "Claude Code" with the bot icon. | Channel shows my name/avatar on prompts and "Claude Code" on replies. |
| 1.5 | ✅ | I see whether Claude has finished a turn at a glance: ⏳ on my prompt while it's working, ✅ once it replies. ❌/⏰/💥/❓ for failure modes. | Reactions on the user's own Slack message: ⏳ pending/running, ✅ complete, ❌ inject failed, ⏰ timeout, 💥 crashed, ❓ AskUserQuestion blocking. Lifecycle: ⏳ on `UserPromptSubmit`, swap to ✅ on `Stop`. Same UX whether the prompt came from local CC or from Slack. | Drive each path manually → reaction transitions match. |
| 1.6 | ✅ | Channels eventually carry the same human-readable name as my Claudian/CC session, so I can find them later. | First reply triggers a background worker that picks a Claudian-style sentence title. Claudian sessions reuse `<vault>/.claudian/sessions/conv-*.meta.json` (zero Bedrock calls). Other surfaces use one Bedrock Haiku 4.5 call. Result fills channel name (slug, ≤70 chars) + topic + state.title. | Start a Claudian conversation → channel renames within 5–30s to the same title Claudian shows. Start a terminal CC session → channel renames to a meaningful sentence within 5–30s. |
| 1.7 | ✅ | When I paste an image into a CC prompt, the same image shows up in Slack so I can see what I asked about from my phone. | Pasted images in CC prompts are extracted from the transcript JSONL and uploaded as the user identity via `files.upload_v2` + permalink unfurl. Anchored to the matching prompt by text. 5 MB cap. | Paste image into CC prompt → image appears under the user's mirrored message in Slack. |
| 1.8 | ✅ | When Claude pops up a multi-choice question, I can read the question and the options from Slack — and I can see what I picked. | `AskUserQuestion` text + options post as Claude Code; the answer the user picks locally is mirrored back as the user identity. (Answering remotely from Slack is a separate research item — see 2.7.) | Trigger `AskUserQuestion` locally → Slack shows the question; answer locally → Slack shows the answer. |
| 1.9 | ✅ | Headings, bold, links, and code blocks from Claude render correctly in Slack instead of looking like raw markdown. | GitHub-flavored markdown (`**bold**`, `## h2`, `[t](u)`, `~~s~~`) converts to Slack mrkdwn; code blocks pass through untouched. | Send a prompt that produces all four → Slack renders correctly. |
| 1.10 | ✅ | CC's internal sub-sessions (title generation, summarization) don't pollute my Slack sidebar with junk channels. | `mirror.sh` skips user prompts matching CC-internal patterns ("Generate a title…", "Your task is to create a … summary"). No state file created for sub-sessions, so subsequent `Stop`/`SessionEnd` for those sub-sessions can't archive a real channel. | Tail mirror log during a CC turn that triggers a sub-session → "skip user (cc-internal noise)" line, no new state file. |

### 2. Slack inputs flow back into CC

| ID | Status | What it means for me | Requirement | Acceptance test |
|---|---|---|---|---|
| 2.1 | ✅ | I can keep an existing CC session going from Slack — type into the channel, Claude picks up where it left off. | Daemon spawns `claude -p --resume <sid>` with my message; reply mirrors back through the normal hook path. | Type a message in a session channel → CC produces a turn, reply lands in the same channel. |
| 2.2 | ✅ | Remote turns can edit files / run commands without prompting me for permission — because I'm not at the keyboard to confirm. | Daemon-spawned subprocess runs with `--permission-mode bypassPermissions`. | Reply from Slack asking CC to write a file → file appears, no permission prompt. |
| 2.3 | ✅ | If I message the bot in DM, I can pause/resume mirroring or list active sessions — global control without opening a session channel. | DM commands: `start` / `resume` (re-enable mirroring), `stop` / `pause` (disable), `status` / `?` (am I on?), `active` / `list` / `sessions` (active sessions), `recent` / `archived` (recently archived). | DM each command → expected response. |
| 2.4 | ✅ | If I reply from Slack while the local CC is mid-turn, my message queues instead of corrupting the transcript by racing two CC processes. | `state.busy` flag set on `UserPromptSubmit`, cleared on `Stop`. `sid_has_live_process(sid)` walks `ps` for any cc command containing the sid that's not in the daemon's pgid. If either says active → message queues to `queue/<sid>.jsonl`. Drainer dispatches when both clear. | Type prompt locally; immediately reply from Slack → reaction stays ⏳, queue file gains an entry, message dispatches when local turn finishes. |
| 2.5 | ✅ | I can start a brand-new CC session from my phone — no laptop in hand, just a DM to the bot. | DM the bot `new <project-path>: <prompt>` (or `<prompt>` on a second line). Daemon spawns a fresh `claude -p` (no `--resume`) with cwd = `<project-path>` and the prompt as first input. The hook chain creates a channel as usual; daemon DM-replies with the new channel link. **Headless only** — no Terminal/iTerm window opens on the Mac. | (a) DM `new ~/Documents/obsidian-vault: list the top three priorities from the todo list` → new channel within ~10s, first user message is the prompt, CC replies in channel. (b) DM `new /nonexistent/path: hi` → daemon DM-replies with an error, no channel. (c) DM `new` with no prompt → daemon DM-replies with usage. (d) Bot does **not** open a Terminal/iTerm window. |
| 2.6 | ❄️ | (Deferred — research only this cycle.) I want to drop an image into a Slack session channel and have CC see it on the next turn. | `claude -p --image-paths` does not exist in current CC build. Research path: (a) does `claude -p` accept JSON content-block input on stdin including image blocks? (b) if not, can the daemon write a transcript JSONL turn directly with an image content block and have CC pick it up on resume? Output: paragraph in `DEVLOG.md` documenting the chosen path. No code this cycle. | DEVLOG paragraph committed; decision recorded. |
| 2.7 | ✅ | Claude rarely uses the multi-choice popup that blocks the local CC and can't be answered from Slack — because vault `CLAUDE.md` instructs it to ask in plain text instead. | Vault root `CLAUDE.md` carries an "AskUserQuestion" rule: *"never call `AskUserQuestion`; ask in plain text instead — `cc-bridge-slack` can't sync tool-blocked sessions."* CC mostly complies. When it slips, the ❓ reaction shows up so I know to handle at the desk. No bridge-side IPC; no remote answer. | Vault `CLAUDE.md` contains the rule. CC sessions over the last week show no `AskUserQuestion` tool calls in transcripts (or, if any, ❓ reaction visible on that prompt in Slack). |

### 3. End and resume sessions from Slack

| ID | Status | What it means for me | Requirement | Acceptance test |
|---|---|---|---|---|
| 3.1 | ✅ | I can end a session from Slack by typing `exit` (or `end` / `archive`) in the channel — no need to switch back to my laptop just to close it. | Plain words `exit` / `end` / `archive` typed in a session channel mark state archived and archive the channel. | Type `exit` in a session channel → channel archives within 2s. |
| 3.2 | ✅ | If I reopen an old session (Claudian reload, `claude --resume`, or a Slack reply), the archived channel comes back automatically. | Resuming an archived session unarchives the channel and clears state's `archived` flag. If `chat.postMessage` fails with `is_archived`, mirror.sh unarchives and retries once. | Resume an archived session → channel reappears in sidebar; `archived` field gone from state. |
| 3.3 | ✅ | When I `/exit` a session in terminal CC or close it in Claudian, the Slack channel archives **immediately** — my sidebar doesn't fill up with finished work. (Historical note: was previously documented as ✅ but only updated state — Slack channel was never archived. Fixed in P0b.) | When `SessionEnd` fires for a sid with state, archive the channel immediately **if** state has no `pending_user_ts` (the last user turn already completed). If `pending_user_ts` is set, defer archive: leave a flag `archive_pending: true`, and the next `Stop` that clears `pending_user_ts` archives at that point. So a session never archives with a hanging unanswered user prompt. | (a) Type `/exit` after CC fully replied → channel archives within 5s. (b) Type `/exit` while CC is mid-turn → channel stays open until Stop fires, then archives. (c) Daemon-spawned reply that ends with SessionEnd → channel does **not** archive (existing from-slack marker guard). |
| 3.4 | ✅ | When a channel auto-archives, the last message is a clear "_session ended · archived_" line — not a half-conversation. | Before archive, post `_session ended · archived_` as Claude Code (one line). Reactions on prior messages are preserved. | Trigger `/exit` → tombstone line is the last message in channel, prior reactions intact. |
| 3.5 | ✅ | If I notice old finished sessions still in my sidebar, I can DM the bot and have them all archived in one shot. Not a background process — only runs when I ask. | DM commands `sweep` / `cleanup` walk every state file: if `state.archived=true` and `slack_archived=false` and the Slack channel still exists, archive it and mark `slack_archived=true`. DM-reply summarizes how many were swept. **No hourly background thread** — 3.3 is the primary mechanism; the sweeper is a manual fallback for when SessionEnd missed. | DM the bot `sweep` → bot replies with count of channels archived. Re-run → bot replies "0 channels need sweeping". |

---

## 5. Operational hygiene & deploy (foundational, not user-facing)

These aren't "what it means for me" features — they're invariants. Listed here so they aren't lost.

| ID | Status | Requirement | Acceptance test |
|---|---|---|---|
| O-01 | ✅ Per-sid mkdir mutex on state writes (10s stale cleanup; replaces missing `flock` on macOS) | Force two concurrent state writes → no JSON corruption. |
| O-02 | ✅ User-id allowlist (`SLACK_USER_ID`) on every inbound event | Second user messages bot → no command runs, log shows reject. |
| O-03 | ✅ State dir mode 0700 | `stat ~/.claude/tools/cc-bridge-state` → 700. |
| O-04 | ✅ Bot token (xoxb) in macOS Keychain; app token (xapp) in 600-mode file | `security find-generic-password` returns xoxb; xapp file is `-rw-------`. |
| O-05 | ✅ from-slack marker sweeper on daemon startup | Drop a stale marker, restart daemon → marker cleared, log line `cleared N orphan from-slack marker(s)`. |
| D-01 | ✅ launchd autostart with KeepAlive + 30s throttle | `launchctl list | grep cc-bridge` returns running PID. |
| D-02 | ✅ `daemon/sync-to-launchd.sh` mirrors source → `~/Library/Application Support/cc-bridge-daemon/` and kickstarts | Run script → live daemon picks up new code on next message. |
| D-03 | ✅ `install.sh` interactive bootstrap (Keychain + env file + token file + state dir + LaunchAgent + hook config) | Fresh-Mac dry run completes without error. |

---

## 6. This-cycle phasing

P0a (verification of existing ✅ features) gates P0b (build new 🔧 features). Same gate from P0 → P1.

### P0a — verify shipped features against acceptance tests
Walk every ✅ row and confirm the acceptance test passes today. Anything that fails moves to 🐛 and gets fixed before P0b begins. Suspected-not-working list (static-only signal):
- **1.5** reactions — confirm a recent channel still shows ⏳→✅ transitions
- **1.6** title sync — confirm last 5 channels carry meaningful titles
- **2.1** channel reply → CC — pick an active session, reply from Slack, verify CC produces a turn
- **3.1** in-channel `exit`/`end`/`archive` — only 1 such state file in 30 days, confirm command still works
- **3.2** unarchive on reopen — resume a known-archived sid, confirm channel reappears
- (Sweeper 3.5 is already known broken — covered in P0b.)

### P0b — shipped 2026-05-25
- ☑ **3.3** archive immediately on SessionEnd, guarded by `pending_user_ts` (primary mechanism)
- ☑ **3.4** final tombstone post before archive
- ☑ **3.5** DM `sweep` command — manual fallback only, no background thread
- ☑ **2.5** mobile-initiated session (DM `new <path>: <prompt>`)
- ☑ **1.6** title-gen rewritten to mirror CC's native `ai-title` (Bedrock removed)

### Deferred to next cycle
- **2.6** Slack → CC image — research-only spike this cycle (no `--image-paths` flag in current CC build)
- **2.7** AskUserQuestion — current CLAUDE.md workaround stands, mark ✅

### Cut / not building
- **1.11** test-session noise filter — manual sidebar cleanup is enough
- **1.12** cwd refresh — no project moves; existing fallback is fine
- **3.6** DM monitor reports — not needed
- Cross-session memory capture — CC's native auto-memory covers it

---

## 7. Usage reference

How to drive the bridge from Slack once it's installed (see `INSTALL.md` for installation).

### 7.1 Bot DM commands

DM the bot directly. All commands are case-insensitive plain text — no slash prefix (Slack would intercept it client-side).

| Command | Effect |
|---|---|
| `start` / `start cc-bridge` / `resume` | Enable mirroring of new sessions. |
| `stop` / `stop cc-bridge` / `pause` | Pause mirroring. New sessions get no channel; in-flight sessions keep working. |
| `status` / `?` | Reply with current state (enabled / paused). |
| `active` / `list` / `sessions` | List currently running sessions with channel link, surface, cwd. |
| `recent` / `archived` | List recently-archived sessions (state-archived but Slack still alive). |
| `new <project-path>: <prompt>` | (🔧 2.5) Start a brand-new CC session headlessly with cwd = `<project-path>` and `<prompt>` as the first input. Bot DM-replies with the new channel link. |
| anything else | Help text. |

The DM is also the fallback channel when the bridge can't reach a session channel.

### 7.2 In-channel commands

Inside a session channel:

| Command | Effect |
|---|---|
| `exit` / `end` / `archive` | Mark the session ended. The local CC process keeps running (we can't safely kill it remotely); the channel archives and state flags `archived=true`. Identical to what happens on CC's `SessionEnd` hook. |
| (image attachment) | (🔧 2.6) The image becomes available to CC for the next turn. |
| anything else | Treated as a prompt injection — daemon spawns `claude -p --resume <sid>` with the session's cwd and the message body. If the session is busy, the message queues and dispatches when `Stop` fires. |

### 7.3 Reactions

Status of every Slack-side **and** locally-typed prompt is shown as a reaction on the user's own message. Same indicators regardless of origin.

| Reaction | Meaning |
|---|---|
| ⏳ `:hourglass_flowing_sand:` | Daemon received the message; queued or running. |
| ✅ `:white_check_mark:` | Turn complete. |
| ❌ `:x:` | Inject failed (cwd missing, exit ≠ 0). Check `/tmp/cc-bridge-daemon.log`. |
| ⏰ `:alarm_clock:` | 10-minute timeout. |
| 💥 `:boom:` | Subprocess crashed before output. |
| ❓ `:grey_question:` | CC hit `AskUserQuestion` — needs local interaction (vault `CLAUDE.md` discourages this; see 2.7). |

### 7.4 Identifying who said what

Each session channel sees four message sources:

| Author | What it means |
|---|---|
| Your real Slack profile | You typed it directly into Slack. |
| `USER_DISPLAY_NAME` with your avatar | Mirrored from local CC — you typed this in terminal/Claudian. |
| `Claude Code` with bot icon | Reply from the model. |
| The bot itself (`cc-bridge`) | System messages: channel created, archived, topic set, file uploaded. |

The latest message's author is the most reliable busy-state indicator: last message from `Claude Code` → session idle. Last message from any user identity → CC is still working.

### 7.5 Off-the-desk workflow

1. Local CC sits idle. Walk away.
2. On phone Slack, open the session channel (or any recent unread).
3. Type a follow-up. ⏳ appears.
4. Daemon spawns `claude -p --resume` on the Mac; transcript gets a new turn.
5. Reply mirrors back as `Claude Code`. ⏳ → ✅.
6. Back at the Mac, run `/resume` in CC (or send a new prompt) to pick up the merged transcript.

Caveats:
- **Bypass-permission injection.** The daemon spawns CC with `--permission-mode bypassPermissions`. Anything CC decides to do runs without asking. `SLACK_USER_ID` allowlist is the only authn — audit before adding any other user.
- **Don't inject into a busy session.** Messages sent during a local turn queue and drain on the next `Stop`. If you keep typing locally too, queue ordering can surprise you.

### 7.6 Logs

- `/tmp/cc-mirror-test.log` — every `mirror.sh` hook fire.
- `/tmp/cc-bridge-daemon.log` — daemon lifecycle, reply route, sweeper.
- `/tmp/cc-bridge-daemon.stderr.log` — uncaught exceptions.

---

## 8. Out of scope

- No public webhook endpoint. Socket Mode only.
- No multi-user. The user-id allowlist is the authn model.
- No iCloud sync of state files. Each Mac is its own world.
- No Slack workflow buttons / interactive blocks. Free-text reply routing is enough.
- No browser dashboard. Slack is the only UI.

---

## 9. Glossary

- **sid**: CC's `session_id` UUID. The primary key everywhere.
- **state file**: `~/.claude/tools/cc-bridge-state/<sid>.json`. One per session.
- **from-slack marker**: empty file at `<state>/from-slack/<sid>`. Signals "next hook fire is from a daemon subprocess; skip user-mirror and skip SessionEnd-archive."
- **busy**: `state.busy=true` between `UserPromptSubmit` and `Stop`. Used to queue inbound Slack messages.
- **pending_user_ts**: Slack message ts of the most recent user prompt that has the ⏳ reaction. Cleared when `Stop` swaps it to ✅. The guard for "is a user turn currently outstanding".
- **slack_archived**: `state.slack_archived=true` once the Slack channel itself is archived (separate from `state.archived` which records the lifecycle event in our own state).
