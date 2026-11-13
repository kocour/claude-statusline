# claude-statusline

A statusline for Claude Code that shows model, directory and git info, context and plan-limit usage, a prompt-cache countdown, and an optional cache keep-alive for long sessions.

Based on [claude-statusline](https://github.com/kamranahmedse/claude-statusline) by Kamran Ahmed.

![demo](./.github/demo.png)

Calm (last response 8 minutes ago):

```
Opus 5.5 │ claude-statusline (main) │ ⏱ 1h12m │ ● high

context ████▒▒▒▒▒▒  42% ⟳ 84k/200k   │   cache 52m
current ███▒▒▒▒▒▒▒  31% ⟳ 15:12      │   weekly ██▒▒▒▒▒▒▒▒  22% ⟳ Nov 12, 09:00   │   fable ▒▒▒▒▒▒▒▒▒▒   6%
```

Hot (cache about to expire, 5 h limit running ahead of the clock):

```
Opus 5.5 │ claude-statusline (main*) │ ⏱ 2h40m │ ● high

context ███████▒▒▒  78% ⟳ 156k/200k   │   ⧗ cache 12m ♻
current ███████▒▒▒  73%↑ ⟳ 15:12      │   weekly ████▒▒▒▒▒▒  41% ⟳ Nov 12, 09:00
```

## Install

The package is not published to npm yet, so install it from the repository:

```bash
git clone https://github.com/kocour/claude-statusline ~/.claude-statusline
node ~/.claude-statusline/bin/install.js
```

Restart Claude Code afterwards.

To update, pull and re-run the installer:

```bash
git -C ~/.claude-statusline pull
node ~/.claude-statusline/bin/install.js
```

Once it is on npm, `npx @kocour/claude-statusline` will do the same.

The installer:

- backs up your existing statusline script (if different) and copies `statusline.sh` to `~/.claude/statusline.sh`
- sets `statusLine` in `~/.claude/settings.json`, including `refreshInterval: 30` so the cache countdown keeps ticking while the session is idle
- installs the keep-alive hook (`~/.claude/keepwarm-hook.sh`, registered under `hooks.UserPromptSubmit`) and the `/keepwarm` skill (`~/.claude/skills/keepwarm/`)

Re-running it is safe: it does not duplicate the hook and leaves other hooks untouched. If `settings.json` cannot be parsed or has an unexpected shape, the installer stops before changing anything.

## Requirements

- Claude Code 2.1.251 or newer (the cache countdown needs `prompt_cache` in the statusline input)
- [jq](https://jqlang.github.io/jq/), curl, git
- Node.js 18 or newer (for the installer only)

On macOS:

```bash
brew install jq
```

## What the statusline shows

- **Bars** are 10 blocks wide, colored mint, orange, yellow or red as usage grows.
- **`context`** shows context window usage and token counts.
- **`current` / `weekly`** show the 5 hour and 7 day plan limits and their reset times. Per-model weekly limits (e.g. `fable`) follow `weekly` when your plan has them; their reset time is shown only when it differs from the weekly one. An `extra` usage line appears when extra usage is enabled.
- **`cache`** is the time left on the prompt cache:
  - more than 25 min: white `cache 52m`
  - 25 min or less: yellow `⧗ cache 12m`
  - 5 min or less: red `⧗ cache 3m`
  - expired: dim `cache cold`
  - hidden if Claude Code reports no caching yet
- **`↑`** after a limit's percentage means usage is at least 10 points ahead of the elapsed time in that window.
- **`♻`** after the cache countdown means keep-alive is running for this session (its marker was refreshed in the last 50 minutes). It can show for up to 50 minutes right after keep-alive is requested, before the first ping confirms the cron job.

## Cache keep-alive

When you pause a long session, the prompt cache expires and the next message re-reads the whole context at full price. Keep-alive prevents that with a small ping every 30 minutes, for up to 4 hours without your input. It only works with the 1 hour cache; it does nothing on a 5 minute cache.

It is per session: each session that qualifies gets its own, and it ends with that session.

**Starts automatically** once per session, on your first prompt after the context reaches 50k tokens on a 1 hour cache. It is not started again after that, even if you stop it.

**Commands**

- `/keepwarm` starts keep-alive for the current session.
- `/keepwarm off` stops it (and prevents the automatic start in that session).

**Stops by itself** when any of these is true at a ping:

- 4 hours have passed since your last input
- there is no record of your input
- the cache TTL is known to be something other than 1 hour
- the 5 hour or 7 day plan usage is at 90 % or more

It also will not start under the last two conditions.

**How it works**

A `UserPromptSubmit` hook makes every decision and writes small state files in `~/.claude/statusline-state/`. The skill only creates or deletes a session cron job (`CronCreate`, `CronList`, `CronDelete`) that sends `[keepwarm] cache keep-alive ping` every 30 minutes. The hook treats a prompt as a ping only if it starts with that text (verified against Claude Code 2.1.319, where a cron-fired prompt arrives verbatim; re-check after Claude Code upgrades), so pasted output that merely mentions it is normal input. A ping is answered with `ok` and no tools. While you are actively using the session (the cache has more than 40 minutes left), the hook blocks the ping before it reaches the API, so it costs nothing. The skipped ping leaves a notice in the transcript, `keepwarm ✓ cache is still warm, no ping needed (nothing is wrong)`; it appears roughly every 30 minutes while you work and is expected.

**Costs**

Each ping that reaches the API is one request that reads the full context from cache. On the API that is about 0.1x the input price; on a subscription it counts toward your 5 hour and 7 day limits. In the worst case, an abandoned session gets about 8 pings over 4 hours. With a 150k-token context that is 8 x 150k cache-read tokens, roughly the cost of one cold re-cache. So keep-alive pays off if you come back within 4 hours, and costs at most about one re-cache if you do not.

Note: while keep-alive runs, Claude Code's built-in idle compaction (1 hour cache, 200k+ tokens, idle about an hour) does not trigger.

## Uninstall

```bash
node ~/.claude-statusline/bin/install.js --uninstall
```

This restores your previous statusline from the backup if there is one (the `statusLine` setting stays, only the `refreshInterval` it added is removed), otherwise removes `statusline.sh` and the `statusLine` setting. It also removes the keep-alive hook entry (only ours; other hooks stay), `keepwarm-hook.sh`, the `keepwarm` skill and the `~/.claude/statusline-state/` directory. Restart Claude Code afterwards.

## License

MIT
