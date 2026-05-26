# cc-bridge-slack — Implementation Plan

Execution plan for the 🔧 features in PRD.md §6 P0b. PRD.md is the **what**; this is the **how**. Each task lists files touched, lines, risk, and the acceptance test that gates moving to the next task.

Status legend: ☐ pending · ▣ in progress · ☑ done · ⨯ rolled back.

## Status as of 2026-05-25 21:30

All 8 tasks ☑. 28 of 28 acceptance tests pass. Daemon redeployed and healthy (PID 27396). See `BETA-CHECKLIST.md` for the 3 user-driven verifications.

---

## State at start of execution

- **Done already (verified live)**: P0a — all of PRD §4 marked ✅ pass acceptance tests except 2.1 (verified historically only — bot can't post-as-user, but daemon log shows past successes).
- **Bug found during P0a**: PRD's "Auto-archive on SessionEnd" is documented ✅ but the code only sets `state.archived=true` — Slack channel never archives. The broken hourly sweeper was supposed to catch up; it ran twice ever. This is the root cause of the 97-channel sidebar pile-up.
- **Sweep already executed manually**: 9 test sessions deleted, 7 orphans archived, 89 stale swept. Sidebar is clean as of 2026-05-25 19:30.
- **Title-gen rewrite already executed (Task 1)**: this current session's channel renamed from `session-57015efc` to `fix-slack-channel-archiving-and-add-reverse-messaging` via the new transcript-jsonl tail path. Bedrock fully removed.

---

## Tasks

### ☑ 1. Title-gen rewrite — Bedrock out, native sources only

**Why**: Current code calls `aws bedrock-runtime invoke-model` for every non-Claudian session and was failing with `bedrock invoke failed` on this Mac. CC already writes a native `ai-title` line into the transcript jsonl for every surface. Mirror that, no LLM call.

**Files**:
- `title-generator.sh` — full rewrite (~80 lines deleted, ~10 added). Two sources only: Claudian meta.json (existing path), or `jq -r 'select(.type=="ai-title" and .sessionId==$sid) | .aiTitle' <transcript>`. Single pass, no polling.
- `mirror.sh` lines 702–719 — fire title-gen on every assistant `Stop` while `state.renamed != true`, not just the first reply.

**Risk**: low. Isolated background script, harmless re-fires (idempotent on `state.renamed`).

**Acceptance test (solo-driven)**:
- (a) ☑ `bash title-generator.sh 57015efc-…` on this session's sid (which had `renamed=false`) → state's `renamed=true, title="Fix Slack…"`, channel sidebar name updates. **VERIFIED 2026-05-25 20:00.**
- (b) Spawn `claude -p` subprocess in `/tmp/cc-bridge-test/` with prompt `count to 5`. Wait 90s. `jq -r .renamed` on the new state file == `true`, `jq -r .title` is non-empty.
  ```bash
  cd /tmp/cc-bridge-test && claude -p --permission-mode bypassPermissions "count to 5" &
  sleep 90; sid=$(ls -t ~/.claude/tools/cc-bridge-state | head -1 | sed 's/.json//')
  jq '{renamed, title}' ~/.claude/tools/cc-bridge-state/$sid.json
  ```
- (c) Pick a recent Claudian state with `renamed=true`, manually flip `renamed=false`, run `title-generator.sh <sid>` → state reverts to `renamed=true`, title unchanged.
- (d) Run `time title-generator.sh <renamed_sid>` → exits in <100ms (state.renamed=true short-circuits before any curl).

---

### ☐ 2. Archive on SessionEnd, guarded by `pending_user_ts` + tombstone post

**Why**: Today `mirror.sh` end-case writes `state.archived=true` but does not archive the Slack channel. Sweeper was supposed to catch up but is broken (Task 3). Switch the primary mechanism to be SessionEnd-archives-immediately, with a guard so we never archive a channel where the last user prompt is still hanging.

**Files**:
- `mirror.sh` `end)` case (~line 740–776). Replace block with:
  - Read `pending_user_ts` from state.
  - If set → write `archive_pending: true` flag + `archived: true`, exit. The next `Stop` will see `archive_pending=true` AFTER it clears `pending_user_ts` and execute the deferred archive.
  - If not set → post tombstone `_session ended · archived_` as Claude Code, then `archive_channel "$CHANNEL_ID"`, then write `slack_archived: true`.
- `mirror.sh` `assistant)` case (~line 728–737). After clearing `pending_user_ts` (existing code), check `archive_pending`. If true → tombstone + archive + write `slack_archived: true`.

**Lines**: ~25 changed in `end)`, ~10 added in `assistant)`.

**Risk**: medium. Touches lifecycle. Existing `from-slack` marker guard at line 752 stays — must not archive on synthetic SessionEnds from daemon-spawned `claude -p`.

**Acceptance test (solo-driven)**: I drive every test from Bash without your CC interaction.

- (a) **Post-reply exit archives**:
  ```bash
  cd /tmp/cc-bridge-test && claude -p --permission-mode bypassPermissions "say ok" </dev/null
  # claude -p auto-fires SessionEnd at exit. Wait, then check.
  sleep 10
  sid=$(ls -t ~/.claude/tools/cc-bridge-state | head -1 | sed 's/.json//')
  ch=$(jq -r .channel_id ~/.claude/tools/cc-bridge-state/$sid.json)
  archived=$(curl -s -X POST https://slack.com/api/conversations.info -H "Authorization: Bearer $TOKEN" -d "channel=$ch" | jq .channel.is_archived)
  test "$archived" = "true" && echo PASS || echo FAIL
  # Also check tombstone is the last message
  curl -s ... conversations.history limit=1 | jq -r '.messages[0].text' | grep -q 'session ended · archived' && echo PASS-tombstone
  ```
- (b) **Mid-turn exit defers**: harder to script because I need to fire SessionEnd while CC is still mid-turn. Approach: invoke `mirror.sh end` directly with a payload referencing a sid where I've manually pre-set `pending_user_ts` in state. After the call, state has `archive_pending=true` and channel is NOT archived. Then post a synthetic Stop event that clears `pending_user_ts` → expect channel archived + `slack_archived=true`.
  ```bash
  # Fake a state with pending_user_ts set
  sid=test-defer-$(date +%s)
  jq -n --arg s "$sid" '{session_id:$s, channel_id:"<known-test-channel>", pending_user_ts:"1234.5678"}' \
    > ~/.claude/tools/cc-bridge-state/$sid.json
  # Fire end hook
  echo '{"session_id":"'$sid'","reason":"test"}' | bash mirror.sh end
  # Expect: archive_pending=true, slack_archived missing/false
  jq '{archive_pending, slack_archived}' ~/.claude/tools/cc-bridge-state/$sid.json
  # Now fire Stop → expect deferred archive runs
  echo '{"session_id":"'$sid'","message":{"role":"assistant","content":"done"}}' | bash mirror.sh assistant
  # Expect slack_archived=true
  ```
- (c) **From-slack inject does not archive**:
  ```bash
  sid=test-fromslack-$(date +%s)
  # Set up state file with channel + drop from-slack marker
  jq -n --arg s "$sid" '{session_id:$s, channel_id:"<known-test-channel>"}' > ~/.claude/tools/cc-bridge-state/$sid.json
  touch ~/.claude/tools/cc-bridge-state/from-slack/$sid
  # Fire end hook (simulates the synthetic SessionEnd from claude -p subprocess)
  echo '{"session_id":"'$sid'","reason":"resume-finish"}' | bash mirror.sh end
  # Expect: state unchanged, channel still active
  jq 'has("archived")' ~/.claude/tools/cc-bridge-state/$sid.json  # → false
  ```
- All three pass = Task 2 ☑.

---

### ☐ 3. DM `sweep` command + remove background hourly sweeper thread

**Why**: PRD 3.5 — sweeper becomes manual, only fires on demand. Removes the surprise of the hourly thread silently changing your sidebar; gives you control.

**Files**:
- `daemon/main.py` line 750 — delete `threading.Thread(target=archive_sweeper, daemon=True).start()`.
- `daemon/main.py` `archive_sweeper` function (~line 673–716) — keep the per-iteration body, drop the `while True / sleep(3600)` wrapper. Rename to `sweep_once(grace_days=0)` returning `(archived_count, error_count)`.
- `daemon/main.py` DM handler (~line 432) — add new branch: if cmd in `("sweep", "cleanup")` → call `sweep_once(grace_days=0)`, DM-reply with the count.

**Lines**: ~30 added (DM branch), ~10 modified (sweep_once shape), ~3 deleted (thread launch).

**Risk**: low. The function is already known-working (the manual sweep this session used the same `conversations.archive` calls).

**Acceptance test (solo-driven)**: I can't post-as-user via the bot token (SLACK_USER_ID allowlist correctly rejects). Two-phase test:

- (a) **Unit test the `sweep_once()` function directly** (drives the Slack API logic without going through DM):
  ```bash
  # Set up: pick a non-test live channel, manually set state.archived=true,slack_archived=false
  test_sid=...; test_channel_id=...
  cp ~/.claude/tools/cc-bridge-state/$test_sid.json /tmp/state-backup.json
  jq '. + {archived:true, archived_at:"2026-05-25T20:00:00Z", slack_archived:false}' \
    ~/.claude/tools/cc-bridge-state/$test_sid.json > /tmp/x && mv /tmp/x ~/.claude/tools/cc-bridge-state/$test_sid.json
  # Verify channel is open in slack
  python3 -c "...conversations.info..."  # is_archived: false
  # Run sweep_once via direct daemon import
  cd dev/tools/cc-bridge-slack/daemon && python3 -c "from main import sweep_once; print(sweep_once(grace_days=0))"
  # Expect (1, 0)  — 1 archived, 0 errors
  # Verify channel is now archived + state has slack_archived=true
  ```
- (b) **DM-handler test via direct call to the handler function** (bypasses Slack delivery, exercises the routing):
  ```bash
  python3 <<PY
  from daemon.main import handle_dm_command  # may need to expose this
  result = handle_dm_command("sweep", user_id="<allowlisted>")
  assert "swept" in result.lower()
  PY
  ```
- (c) **Verify the hourly thread is gone**: `grep "Archive sweeper" /tmp/cc-bridge-daemon.log | tail` shows no new entries after deploy. `ps -p <daemon_pid> -M | wc -l` shows one fewer thread vs. before.
- After deploy: I trigger sweep myself by calling daemon.main `sweep_once()` directly via a one-shot Python invocation; you confirm by DMing `sweep` from your phone after I'm done — that's the only step requiring you, and it happens after I've already passed (a)/(b)/(c).

---

### ☐ 4. DM `new <path>: <prompt>` — mobile-initiated session

**Why**: PRD 2.5. Single biggest workflow add — start a brand-new CC session from a phone DM, no laptop interaction.

**Files**:
- `daemon/main.py` DM handler — add branch: parse `^new\s+([^:]+?):\s*(.+)$` (path before `:`, prompt after). Path can also be on first line and prompt on second line.
- Validate: `os.path.expanduser` + `os.path.expandvars`, then `pathlib.Path(path).is_dir()`. If invalid → DM-reply error.
- Spawn detached subprocess: `subprocess.Popen(["claude", "-p", "--permission-mode", "bypassPermissions", prompt], cwd=path, stdout=DEVNULL, stderr=DEVNULL, start_new_session=True)`. Do NOT use `--resume` — we want a fresh sid.
- The hook chain (`UserPromptSubmit` → `mirror.sh user`) creates the channel as usual.
- Watch state dir for a new `<sid>.json` whose `cwd == <path>` and `created` > our spawn time. Up to 30s. Once found → DM-reply with `<#channel_id>` link.

**Lines**: ~50 added.

**Risk**: medium. New spawn path; need to make sure the daemon doesn't create a `from-slack` marker (this isn't a resume, it's a brand-new session — markers exist to suppress duplicate user-mirror, which we WANT here).

**Acceptance test (solo-driven)**: Same allowlist constraint as Task 3. Test via direct handler invocation.

- (a) **Happy path via direct call**:
  ```bash
  python3 <<PY
  from daemon.main import handle_new_session_command
  result = handle_new_session_command("new /tmp/cc-bridge-test: respond with the literal word ok",
                                      user_id="<allowlisted>")
  print(result)  # expect a string containing channel link
  PY
  # Wait 30s for hook chain to land
  sleep 30
  # Find the new state file
  newest=$(ls -t ~/.claude/tools/cc-bridge-state/*.json | head -1)
  jq '{cwd, channel_id, surface}' "$newest"
  # Expect cwd=/tmp/cc-bridge-test, surface=obsidian-terminal (or similar from headless claude)
  ```
- (b) **Multi-line variant**: pass `"new /tmp/cc-bridge-test\nrespond with the literal word ok"` to handler → same outcome.
- (c) **Bad path**:
  ```bash
  python3 -c "from daemon.main import handle_new_session_command; print(handle_new_session_command('new /no/such/path: hi', user_id='...'))"
  # Expect string starting with "path not a directory" or similar error
  # No new state file created
  ```
- (d) **No body**:
  ```bash
  python3 -c "from daemon.main import handle_new_session_command; print(handle_new_session_command('new', user_id='...'))"
  # Expect usage example
  ```
- (e) **Tilde expansion**: `new ~/Documents/obsidian-vault: tell me 1+1` → expanded to `/Users/xzixuan/...` and runs.

After all five pass via direct handler, I sync to launchd and you DM `new …` from your phone for the live end-to-end check. That's the only step needing your hands.

---

### ☐ 5. Strip Bedrock keys from `slack-bridge.env`

**Files**: `~/.claude/tools/slack-bridge.env` only — comment out or delete `AWS_PROFILE`, `AWS_REGION`, `BEDROCK_MODEL_ID` if present (only those that were specifically for title-gen — leave any that other tools reference). Verify nothing else in `dev/tools/cc-bridge-slack/` references them via `grep -r`.

**Lines**: ~3 deleted from env file.

**Risk**: none if grep is clean.

**Acceptance test**: `grep -rE 'BEDROCK|aws bedrock|AWS_PROFILE' dev/tools/cc-bridge-slack/` returns no hits in shipped code (matches in docs/comments OK).

---

### ☐ 6. PRD touchup

**Why**: PRD lists "Auto-archive on SessionEnd" implicitly under L-02 (in-channel exit) and historical FEATURES.md called it ✅. After Task 2 ships, add a short note: "Auto-archive on SessionEnd was historically broken — only state was archived, not Slack channel. Fixed in Task 2 of PLAN.md."

**Files**: `docs/PRD.md` — one line added near 3.3, plus toggle 2.7 status from ❄️ to ✅ (workaround stands per directive).

**Lines**: ~5.

**Acceptance test**: visual review.

---

### ☐ 7. Deploy + full P0 acceptance suite

**Why**: launchd runs the daemon from `~/Library/Application Support/cc-bridge-daemon/`, not from the repo. Source must be synced + daemon kickstarted.

**Steps**:
1. `bash daemon/sync-to-launchd.sh` — copies python source + venv pointer.
2. `launchctl kickstart -k gui/$(id -u)/com.cc-bridge.daemon` — restart daemon picking up new code.
3. Verify daemon up: `launchctl list | grep cc-bridge` shows running PID.
4. Run all Task-2/3/4 acceptance tests on fresh sessions in `/tmp/cc-bridge-test/`.
5. Make sure /tmp/cc-bridge-daemon.log shows no errors during the runs.

**Risk**: low. `sync-to-launchd.sh` is the canonical path.

**Acceptance test**: every row in PRD §4 with status 🔧 (now ✅) passes its acceptance test, and tail of `/tmp/cc-bridge-daemon.log` shows no Python tracebacks.

---

### ☐ 8. Commit + submodule bump

**Steps**:
1. In `dev/tools/cc-bridge-slack/`: `git add -A`, review with `git diff --cached`, commit with message describing the four feature changes.
2. **Don't push to remote**. You decide push timing.
3. In parent `dev/tools/`: `git submodule update` shows the bump; `git add cc-bridge-slack && git commit -m "bump cc-bridge-slack to <sha>"`.
4. Don't push parent either.

**Risk**: low. Only local commits; remote push waits for your say-so. (Pushing parent → main triggers VPS auto-deploy of `tools.mrbear929.com`, but cc-bridge-slack is not exposed in that website — only the submodule pointer changes.)

**Acceptance test**: `git status` clean in both repos. `git log -1` shows the new commit.

---

## Stopping rules

- If Task 2 acceptance test (b) fails (mid-turn `/exit` defer doesn't work), stop and review with you. Don't proceed to Task 3.
- If Task 4 acceptance test (a) fails (DM `new` doesn't create a channel), stop and review.
- All other failures: roll back the failing task's changes, mark ⨯, continue with the rest.

## Rollback

Each task is one or two file edits. Roll back via `git checkout -- <file>`. Title-gen rewrite (Task 1) deleted `~70 lines`; if rolled back later, restore from `git show HEAD~1:dev/tools/cc-bridge-slack/title-generator.sh`.

## Beta handoff package

When all tasks ☑ I leave you with:

1. `docs/PLAN.md` — every task marked ☑ with one-line evidence link to log lines.
2. **Beta-test checklist** for you (a separate `docs/BETA-CHECKLIST.md` I'll generate at the end). Three items, takes <5 min:
   - End a real Claudian session → confirm channel archives within 5s with `_session ended · archived_` tombstone.
   - DM the bot `sweep` → expect `0 channels need sweeping` reply (because Task 2 already auto-archives so nothing should be left to sweep).
   - DM the bot `new ~/Documents/obsidian-vault: list the top 3 priorities from todo` → confirm new channel appears within ~15s.
3. `git status` clean in `dev/tools/cc-bridge-slack/` and `dev/tools/`. **No git push.** You decide push timing after beta-test passes.
