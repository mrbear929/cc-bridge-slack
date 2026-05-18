# Feature inventory

The complete picture of what works, what's half-built, what's
intentionally not built, and what's queued.

## ✅ Done — works in production

### Mirroring (CC → Slack)

- [x] **Channel per session.** Every CC `session_id` gets its own
  private Slack channel created on the first `UserPromptSubmit`.
- [x] **User identity override.** Prompts post as a configurable
  display name + avatar (`USER_DISPLAY_NAME`, `USER_ICON_URL`).
- [x] **Claude Code identity.** Replies post as "Claude Code" with
  the bot icon.
- [x] **Init message.** First message in the channel summarizes
  Started time, Surface (terminal/Claudian/iTerm/etc), Device,
  Cwd, full Session UUID, and full Transcript path.
- [x] **Channel topic auto-population.** Topic shows
  `session: <sid> · surface: <surface> · cwd: <path>`.
- [x] **Surface detection.** Recognizes obsidian-claudian,
  obsidian-terminal, native-terminal, iterm, warp, vscode, cursor,
  and falls back to "unknown" gracefully. Uses
  `__CFBundleIdentifier` env first, ppid chain second.
- [x] **GitHub markdown → Slack mrkdwn conversion.** `**bold**`,
  headings, links, strikethrough all converted; code blocks
  protected.
- [x] **Image mirroring.** Pasted images in CC prompts are
  extracted from the transcript JSONL and uploaded as the user
  identity via `files.upload_v2` + permalink unfurl. Anchored to
  the matching prompt by text. 5 MB cap.
- [x] **AskUserQuestion mirror (read-only).** Question text and
  options are mirrored to the channel as Claude Code; the answer
  the user picks locally is mirrored back as the user identity.

### Channel lifecycle

- [x] **Async title rename.** First reply triggers a background
  worker that picks a Claudian-style sentence title (reused from
  Claudian's own meta.json if available, otherwise one Bedrock
  Haiku 4.5 call). Channel renames + topic updates ~5–30s after
  the reply lands.
- [x] **Auto-archive on SessionEnd.** Terminal `/exit` and Claudian
  conversation close fire `SessionEnd`, which archives the channel.
- [x] **Auto-unarchive on reopen.** Reopening an old session in
  Claudian (or hitting it via `claude --resume` in terminal)
  triggers `UserPromptSubmit`, which unarchives the channel and
  clears the archived flag in state.
- [x] **In-channel exit command.** Plain words `exit` / `end` /
  `archive` typed in a session channel archive that channel and
  flag the state.
- [x] **`is_archived` self-heal.** If a post fails because the
  channel was archived behind our back, mirror.sh unarchives and
  retries.

### Reply routing (Slack → CC)

- [x] **Channel reply → CC inject.** Daemon spawns
  `claude -p --resume <sid>` with the message as the prompt.
  Reply mirrors back through the normal hook path.
- [x] **`--permission-mode bypassPermissions`.** So remote turns
  can run shell commands, edit files, push code without prompting.
- [x] **DM control commands.**
  - `start` / `start cc-bridge` / `resume` — re-enable mirroring
  - `stop` / `stop cc-bridge` / `pause` — disable mirroring
  - `status` / `?` — am I on?
  - `active` / `list` / `sessions` — list current sessions
- [x] **Reaction-based status.** Hourglass while pending/running;
  checkmark on completion; x / alarm-clock / boom / question-mark
  for the various failure modes.
- [x] **Hourglass for local prompts too.** When you type into CC
  locally (terminal/Claudian), the mirrored Bear-identity post
  gets ⏳ on `UserPromptSubmit` and ✅ on `Stop`. Slack-side and
  local-side share the same UX.
- [x] **Queue when busy.** If the daemon arrives during a turn it
  enqueues to `queue/<sid>.jsonl`. The drainer runs claude -p
  when `state.busy` flips false.
- [x] **Live-process detection.** `sid_has_live_process(sid)`
  scans `ps` for any cc command containing the sid that's not in
  the daemon's own pgid. If the local user is actively in CC,
  the daemon queues rather than races.

### Operational hygiene

- [x] **Per-sid mkdir mutex.** mirror.sh and daemon coordinate on
  state-file writes via `<state>/.lock-<sid>` (mkdir is atomic on
  POSIX). 10s stale-lock cleanup.
- [x] **User-id allowlist.** Daemon refuses any inbound Slack event
  whose `user` doesn't match `SLACK_USER_ID` from the env file.
  Closes the "bot in a shared channel" command-injection path.
- [x] **State dir mode 700.** Both mirror.sh and daemon set this
  on creation.
- [x] **Token storage in macOS Keychain** (xoxb) and a 600-mode
  file (xapp).
- [x] **Sub-session noise filter.** mirror.sh skips
  `UserPromptSubmit` events whose prompt is CC-internal
  ("Generate a title for this conversation", "Your task is to
  create a … summary"). Sub-sessions never get state files,
  which guards subsequent `Stop` / `SessionEnd` from polluting.
- [x] **From-slack marker file.** Inside daemon-spawned cc-resume
  runs, a marker tells mirror.sh to skip the synthetic user post
  (the Slack message is already in the channel) and the
  synthetic SessionEnd archive (resume's exit isn't a real exit).
- [x] **Marker orphan sweep on daemon startup.** Picks up after
  any previous-life crash so leaked markers don't permanently
  silence mirroring.

### Deployment & lifecycle

- [x] **launchd autostart.** Daemon runs as a LaunchAgent at
  `~/Library/LaunchAgents/com.cc-bridge.daemon.plist`. KeepAlive
  + RunAtLoad. Restarts on crash with 30s throttle.
- [x] **Source ↔ launchd sync script.**
  `daemon/sync-to-launchd.sh` copies code into the launchd-
  friendly `~/Library/Application Support/cc-bridge-daemon/`
  (macOS privacy blocks launchd from `~/Documents`) and
  kickstarts the service.
- [x] **`install.sh`.** Interactive bootstrap on a fresh Mac:
  prompts for tokens, writes Keychain item + env file + token
  file, sets up state dir, optionally registers the LaunchAgent,
  prints the hook block to paste into `~/.claude/settings.json`.
- [x] **Daemon transient-port-friendly.** Socket Mode uses
  outbound WebSocket only. No public endpoint, no port forward.

### Documentation

- [x] **README** (top-level pointer + this docs/ tree)
- [x] **docs/README.md** — architecture, state shape, tokens,
  surface detection, title source, mirror→Slack→mirror loop
  avoidance.
- [x] **docs/INSTALL.md** — fresh-Mac bootstrap, Slack app
  scopes, smoke test, troubleshooting matrix.
- [x] **docs/USAGE.md** — DM commands, in-channel commands,
  reaction status, off-the-desk workflow, who-said-what.
- [x] **docs/DEVLOG.md** (this folder) — current architecture,
  invariants, known sharp edges.
- [x] **docs/FEATURES.md** — this file.

## ⏳ Pending — known wanted, not yet done

### Daemon DM expansion

- [ ] **Monitor reports.** `weekly` / `monthly` / `today` DM
  commands that summarize active vs archived sessions, total
  turns, cwd distribution. State files already carry everything
  needed; just add aggregation in `main.py`.
- [ ] **Test session noise filter.** Auto-skip channel creation
  when cwd is the cc-bridge-slack repo itself, or session
  duration < 30s, or the prompt matches `^(test|hello world|ok|
  yes|hi)$`. Reduces channel pollution from quick smoke tests.

### Reply routing reach

- [ ] **Mobile-initiated session.** DM the bot
  `new <project-path>: <prompt>` to start a brand-new CC
  session on the Mac, with the bot's project path becoming the
  cwd and the message becoming the first prompt. mirror.sh's
  hook chain then creates a channel as usual.
- [ ] **Image upload retry.** Currently a failed
  `files.upload_v2` step1/step2 silently drops the image. Add a
  bounded retry queue with backoff.

### Sharp edges to file down

- [ ] **AskUserQuestion remote answer (real fix).** Either patch
  the realclaudian Obsidian plugin to accept "synthetic answer
  via file" or instrument CC's tool-call infrastructure with an
  external IPC. Both are hard. The current workaround
  (`CLAUDE.md` instructs CC not to call AskUserQuestion) is a
  90% solution.
- [ ] **Transcript fork merging.** When daemon-spawned cc-resume
  writes turns, they end up on a fork off the main parent_uuid
  thread. Local Claudian on reload follows main thread and
  doesn't see remote turns. Fix would be to rewrite the parent
  pointer of the daemon's first turn, but the SDK won't accept
  external transcript edits and Claudian caches in memory.
- [ ] **Stale cwd refresh.** `mirror.sh user` should write the
  hook payload's `cwd` back into state on every turn, so
  sessions whose project moved still resume correctly. Today
  there's a fallback to `~/Documents/obsidian-vault` but it's
  hardcoded to one user.

### Cross-session memory

- [ ] **Periodic transcript distillation.** A launchd job that
  walks `~/.claude/projects/.../*.jsonl` and produces searchable
  markdown notes in `learning/captures/`. Useful for "did I
  solve this before?" questions in future sessions. State and
  transcript_path are already persisted; this is mostly
  prompting work.

### Polish

- [ ] **iCloud Keychain sync.** Right now bot token lives in the
  local login keychain. Moving it to the iCloud keychain (via
  Keychain Access GUI, no clean CLI path) would make a fresh
  Mac install one step shorter.
- [ ] **Hook config installer.** `install.sh` currently prints
  the JSON block for the user to paste into
  `~/.claude/settings.json` themselves. Could parse-merge-rewrite
  but that's risky if the user has hand-edited.
- [ ] **`hook-dump.sh` cleanup.** Diagnostic tool from
  development. Nothing references it now; either keep + document
  as a debugging affordance or delete.

## ❌ Won't fix / consciously not built

- **No public endpoint.** Socket Mode only. No webhook. No need.
- **No multi-user support.** Single-user-by-design; the user-id
  allowlist is the only authn model.
- **No built-in iCloud sync** for state files. Each Mac is its
  own world; sessions don't migrate.
- **No Slack workflow buttons / interactive blocks.** Reply
  routing accepts free text; it doesn't need bespoke UIs.
- **No browser dashboard.** All status surfaces through Slack
  reactions / channel messages. If you want a web view, build it
  on top of the state files.

## Resuming this work later

All open items above can be picked up independently. Each one is
< a day of work given the existing infrastructure. Recommended
order if you have a free afternoon:

1. **Stale cwd refresh** (lowest risk, immediate quality of life)
2. **Test session noise filter** (cleans up channel sidebar)
3. **Mobile-initiated session** (the most-requested feature)
4. **Monitor reports** (depends on having more data; let it
   accumulate first)
5. The harder structural fixes (transcript fork merging,
   AskUserQuestion remote answer) only if the workarounds become
   genuinely painful.
