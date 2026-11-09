---
name: keepwarm
description: Keeps the 1 h prompt cache warm while the user is away by scheduling a cheap ping every 30 minutes. Use for `/keepwarm`, for `/keepwarm off` (stop it), and whenever a `keepwarm:` hook message asks for it.
argument-hint: "[off]"
---

# keepwarm

Never read, write or delete files. Use only CronCreate, CronList and CronDelete.

User argument: `$ARGUMENTS`

## Ping turn

If the prompt contains `[keepwarm]`, this is a ping, not the user. Obey the context line `keepwarm verdict` exactly:

- `keepwarm verdict: ok` -> reply `ok`. No tools.
- `keepwarm verdict: stop (...)` -> CronList, CronDelete every job whose prompt contains `[keepwarm]`, reply `keepwarm stopped`. No other tools.
- No verdict in context -> reply `ok`. No tools.

## Off (first word of the argument is exactly `off`, lowercase)

CronList, CronDelete every job whose prompt contains `[keepwarm]`, then confirm in one line.

## Start (anything else, including no argument)

1. If the hook context says `keepwarm: do not start keep-alive (...)`, explain the reason in one sentence and stop.
2. CronList. If a job whose prompt contains `[keepwarm]` exists, say keep-alive is already running and stop.
3. CronCreate with `cron: "13,43 * * * *"`, `recurring: true`, `prompt: "[keepwarm] cache keep-alive ping"`.
4. If CronCreate is refused or fails, say keep-alive did not start and the user can retry with `/keepwarm`; stop.
5. Confirm in one line: the cache is pinged every 30 minutes and keep-alive stops by itself after 4 h without your input.

If you were invoked because of a `keepwarm: this session has ...` nudge, do the Start steps first, then continue with the user's actual message.
