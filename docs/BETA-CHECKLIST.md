# P0b — Beta Test Checklist

3 user-driven verifications. ~5 min total. Run after the daemon has been restarted with the new code (already done — daemon PID `27396`, `⚡️ Bolt app is running!` at 2026-05-25 21:26:52).

If all 3 pass, reply with **"push"** and I'll push the cc-bridge-slack repo + bump the parent submodule pointer. If any fails, tell me which step and what you saw.

---

## ☐ 1. End a real CC session → channel auto-archives

**What to do:**
- In any CC session (terminal or Claudian), wait for the assistant to finish a turn.
- Type `/exit` (terminal) or close the conversation (Claudian).
- Open Slack within ~5s.

**Expected:**
- The channel for that session is no longer in your "Channels" sidebar (it's archived).
- If you click into it from search/recents, the last message is **`_session ended · archived_`**.
- All earlier reactions (⏳/✅) on user prompts are preserved.

**Variant** (only if you want to verify the deferred-archive guard):
- Start a CC session, send a prompt, and *immediately* `/exit` before the reply finishes.
- The channel should NOT archive yet. After the reply lands and the ⏳ flips to ✅, the channel archives within ~5s.

---

## ☐ 2. DM the bot `sweep`

**What to do:**
- DM the cc-bridge bot the single word: `sweep`

**Expected:**
- Bot replies within ~10s with `swept 0 channel(s)` (because Task 1 SessionEnd-archive already covers everything cleanly).
- If the count is non-zero, that means at least one session ended without going through SessionEnd (e.g. a daemon restart while a session was active) — also fine, just means the fallback caught drift.

---

## ☐ 3. DM the bot `new <path>: <prompt>`

**What to do:**
- DM the bot exactly: `new ~/Documents/obsidian-vault: list the top 3 priorities from todo`

**Expected:**
- Within ~15s, bot DM-replies with `<#C…> ready (sid \`abc12345\`)`.
- Click the channel link.
- Channel is private, has the cc-bridge init message at the top, your prompt as the user-identity message, and Claude's reply listing the 3 priorities.
- No Terminal or iTerm window opened on the Mac (headless).

---

## ☐ 4 (optional). Title sync for terminal sessions

If you happen to start a fresh terminal CC session today (in any cwd), the channel name should auto-rename from `session-<sid8>` to a descriptive Claudian-style title within the second or third assistant `Stop` (no Bedrock involved — title is read straight from the transcript jsonl's `ai-title` line). This already worked for this current session — channel went from `session-57015efc` → `fix-slack-channel-archiving-and-add-reverse-messaging`.

---

## What this cycle changed (one paragraph)

`cc-bridge-slack` now archives the Slack channel immediately when a CC session ends, with a guard that defers archive if a user prompt is still hanging unanswered. Title generation no longer calls Bedrock; it mirrors CC's native `ai-title` line in the transcript jsonl. The hourly background sweeper is gone — it's now a manual DM `sweep` command. New: DM `new <path>: <prompt>` spawns a fresh CC session headlessly, useful from a phone with no laptop in hand. PRD/PLAN updated; FEATURES.md and USAGE.md folded into PRD; 28 of 28 acceptance tests pass against the deployed daemon.
