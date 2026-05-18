# Installing cc-bridge-slack on a fresh Mac

## Prerequisites

- macOS 14+ (uses `launchctl bootstrap`, modern Slack app SDK paths).
- Claude Code installed and on `$PATH`. Confirm with `which claude`.
- `uv` for the Python daemon. `brew install uv` if missing.
- `jq` for the bash hooks. `brew install jq` if missing.
- AWS CLI configured with a profile that can call Bedrock (only used
  for terminal-CC sessions where we fall back from Claudian's title).
- A Slack workspace where you control app installation. For Amazon
  internal use, provision a personal sandbox via `/provision` in any
  internal Slack DM (Opus First-Party Apps program).

## 1 — Slack app

1. https://api.slack.com/apps → **Create New App** → **From scratch** →
   pick the workspace.
2. **Socket Mode** → On → generate an app-level token with
   `connections:write` scope. Save the `xapp-...` token.
3. **OAuth & Permissions** → add Bot Token Scopes:
   ```
   channels:manage
   chat:write
   chat:write.customize
   files:read
   files:write
   groups:history
   groups:read
   groups:write
   groups:write.invites
   groups:write.topic
   im:history
   im:read
   im:write
   reactions:read
   reactions:write
   users:read
   ```
4. **Event Subscriptions** → On → Subscribe to bot events:
   `message.im`, `message.groups`.
5. **App Home** → enable Messages tab + "Allow users to send messages".
6. **Install App** → install. Save the `xoxb-...` Bot User OAuth Token.
7. Optional: upload an app icon (used as Claude Code's avatar in
   mirrored channels).

In the Slack client, find your own `User ID` (Profile → ⋮ → Copy
member ID, looks like `U0XXXXXXXXX`). You'll paste it into the env
file in step 4.

## 2 — Clone

```bash
git clone <your-fork-or-this-repo> ~/path/to/tools
cd ~/path/to/tools/cc-bridge-slack
```

The path doesn't matter except that `mirror.sh` is invoked from this
location by CC hooks — wherever you put it, the hook config in step 5
must match.

## 3 — Run the installer

```bash
./install.sh
```

It will:

- Create `~/.claude/tools/` (mode 700).
- Prompt for the **bot token** and store it in macOS Keychain
  (`security add-generic-password -s cc-bridge-slack -a bot-token`).
- Prompt for the **app-level token** and write it to
  `~/.claude/tools/slack-bridge-app.token` (mode 600).
- Prompt for your **user ID**, **display name**, **avatar URL**, and
  Claude Code icon URL → write them to `~/.claude/tools/slack-bridge.env`
  (mode 600).
- Print the JSON block to paste into `~/.claude/settings.json`.

If you re-run the installer, existing keychain / env entries are
overwritten with `-U`.

## 4 — Wire CC hooks

Open `~/.claude/settings.json`. Inside the top-level object, add (or
merge into) a `"hooks"` key. The exact block to paste lives in
`settings.test.json` and is also printed by the installer; with paths
resolved it looks like:

```json
"hooks": {
  "UserPromptSubmit": [
    { "hooks": [{ "type": "command",
      "command": "/abs/path/to/cc-bridge-slack/mirror.sh user" }] }
  ],
  "Stop": [
    { "hooks": [{ "type": "command",
      "command": "/abs/path/to/cc-bridge-slack/mirror.sh assistant" }] }
  ],
  "SessionEnd": [
    { "hooks": [{ "type": "command",
      "command": "/abs/path/to/cc-bridge-slack/mirror.sh end" }] }
  ],
  "PreToolUse": [
    { "matcher": "AskUserQuestion",
      "hooks": [{ "type": "command",
      "command": "/abs/path/to/cc-bridge-slack/mirror.sh question" }] }
  ],
  "PostToolUse": [
    { "matcher": "AskUserQuestion",
      "hooks": [{ "type": "command",
      "command": "/abs/path/to/cc-bridge-slack/mirror.sh answer" }] }
  ]
}
```

Validate the JSON: `python3 -c "import json; json.load(open('~/.claude/settings.json'.replace('~', '$HOME')))"`.
CC reads hooks at session start, so any new CC session picks up the
config. Existing sessions don't.

## 5 — Set up the daemon

The daemon needs to live in a launchd-friendly path; macOS privacy
blocks `launchd` from reading files under `~/Documents`.

```bash
./daemon/sync-to-launchd.sh
```

This copies code into `~/Library/Application Support/cc-bridge-daemon/`,
runs `uv sync` to build the venv, then kicks any existing launchd
service.

Then register the launchd agent:

```bash
cp daemon/launchd/com.cc-bridge.daemon.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cc-bridge.daemon.plist
launchctl enable gui/$(id -u)/com.cc-bridge.daemon
```

Verify:

```bash
launchctl print gui/$(id -u)/com.cc-bridge.daemon | grep -E 'state|pid|last exit'
```

You want `state = running` and `last exit code = (never exited)`.

If the plist's `Label` (currently `com.cc-bridge.daemon`) conflicts with
something else on your system, edit both the source plist and the file
copied into `~/Library/LaunchAgents/`.

## 6 — Smoke test

1. **Hook fires.** Open a new terminal, run `claude`, type any prompt.
   You should see a private channel created in Slack within ~1 second.
2. **Daemon listens.** DM the bot: `status` → should reply
   "cc-bridge is currently *enabled*".
3. **Reply routing.** In the channel that was just created, type a
   short message. You should see `:hourglass:` immediately, then
   `:white_check_mark:` after CC finishes its turn, then a Claude Code
   reply. **Don't** test reply routing in a session that's currently
   in-flight in your terminal — `claude -p --resume` rejects when the
   sid is locked. Try after the local CC has finished its turn.
4. **Archive.** In the terminal, `/exit`. Slack channel archives ~1 s
   later (SessionEnd hook fires).
5. **Reopen.** Send the same channel a new message after unarchiving;
   it should auto-unarchive and continue.

## 7 — Troubleshooting

| Symptom                                                      | Likely cause                                                                                                                                                               |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hook log empty after CC prompt                               | Hooks not in `~/.claude/settings.json` (check you didn't put them in `settings.local.json` — that file ignores hooks)                                                      |
| `daemon/run.sh: Operation not permitted` in launchd stderr   | Source plist has WorkingDirectory pointing at `~/Documents/...` instead of `~/Library/Application Support/cc-bridge-daemon`. Re-run `sync-to-launchd.sh` and re-bootstrap. |
| Daemon: `[Errno 2] No such file or directory: 'claude'`      | launchd PATH doesn't include CC. Add the binary directory in the plist's `EnvironmentVariables/PATH`.                                                                      |
| Reply routing fails: `No conversation found with session ID` | The target session is currently active (a local CC owns the sid). Wait until it's idle or `/exit` to release.                                                              |
| Reactions silently fail (`missing_scope: reactions:write`)   | You didn't add the scope in step 1.3. Add it, **Reinstall** the app, restart the daemon.                                                                                   |
| Channel name doesn't match Claudian sidebar                  | title-generator.sh waits 30 s for Claudian to publish its meta.json. If it's a long Claudian boot, retry by sending a fresh prompt.                                        |
| User-identity messages have wrong avatar                     | Avatar URL in env file expired (Slack edge URLs rotate yearly-ish). Get a fresh URL from your Slack profile and re-run `install.sh`.                                       |

## 8 — Updating later

```bash
git pull
./daemon/sync-to-launchd.sh   # if daemon code changed
```

`mirror.sh` and friends run directly from the git checkout, so a `git
pull` makes them live immediately.
