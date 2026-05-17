# Manual test plan — cc-bridge-slack mirror

## Phase A: dry-run (no token needed)

```bash
cd /Users/xzixuan/Documents/obsidian-vault/tools/cc-bridge-slack
chmod +x mirror.sh

# 1. user prompt event
MIRROR_DRY_RUN=1 ./mirror.sh user <<<'{"prompt":"hello world from test"}'

# 2. assistant event (no transcript path, fallback)
MIRROR_DRY_RUN=1 ./mirror.sh assistant <<<'{"message":"this is the model reply"}'

# 3. empty payload — should silently skip
MIRROR_DRY_RUN=1 ./mirror.sh user <<<'{}'

# 4. inspect log
tail -40 /tmp/cc-mirror-test.log
```

Expect three log entries: 2× DRY_RUN with previews, 1× skip.

## Phase B: real send (after tokens wired)

```bash
# env file in place at ~/.claude/tools/slack-bridge.env, chmod 600
ls -la ~/.claude/tools/slack-bridge.env

# real send — should land in Slack DM on phone
MIRROR_DRY_RUN=0 ./mirror.sh user <<<'{"prompt":"first real bridge ping"}'

# tail log to verify ok
tail -5 /tmp/cc-mirror-test.log
```

Expect: phone Slack DM from `ccbridge` bot containing `[TEST] 🧑 *user*\nfirst real bridge ping`.

## Phase C: live in CC

After Phase B passes:

1. Manually copy hook blocks from `settings.test.json` into `~/.claude/settings.local.json`
2. Open a fresh CC session in any project
3. Send any prompt
4. Phone should buzz with the user prompt
5. After CC finishes responding, phone should buzz again with assistant text

## Disable

Remove the hook blocks from `~/.claude/settings.local.json`. No other cleanup needed.
