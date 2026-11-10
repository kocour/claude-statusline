# Compact statusline with prompt-cache countdown + cache keep-alive

Date: 2026-11-09
Status: draft for review

## Intent

Two related changes to this package (statusline installer for Claude Code):

1. **Statusline** — keep the current layout, but make it more compact, nicer, and show the
   state of the prompt cache, which is currently invisible.
2. **Cache keep-alive** — when a long session is paused (lunch, meeting), keep its prompt
   cache warm so the next message does not pay a full re-cache. Example cost from the
   inspiration: a long conversation's next message costs ~$3.40 instead of ~$0.17 once the
   cache went cold. Keep the cache warm for up to 4 hours without user input, then let it
   go cold.

Inspiration: `docs/cc-status-line.jpeg` (someone else's one-line statusline). The user chose
to keep their own multi-line layout and borrow selected ideas from it.

Both parts ship as part of this npm package: `bin/install.js` installs and uninstalls
everything.

## Goals

- Fewer lines: `current` and `weekly` limits on one line.
- Block-style progress bars instead of `●○` dots.
- Prompt-cache countdown in the `context` line, always visible, colored only when it matters.
- Pace indicator `↑` when plan usage runs ahead of the clock.
- Countdown stays accurate while the session is idle.
- Keep-alive that starts automatically for large sessions, can be started/stopped manually,
  and stops by itself after 4 h without user input.

## Non-goals

- Redesigning line 1 (model │ dir (branch*) │ ⏱ session │ effort) — unchanged.
- Switching rate-limit data from the OAuth usage API (curl) to the statusline's stdin
  `rate_limits` field. Stdin does not expose `extra_usage`, so the curl path stays. Possible
  future cleanup.
- Clickable links, worktree/scratchpad segments from the inspiration.
- Keep-alive surviving a closed Claude Code session.

## Anti-goals (failure even if it "works")

- Keep-alive that keeps pinging forever, or on sessions the user abandoned — it consumes plan
  limits. The 4 h cut-off is a hard requirement.
- Keep-alive running where it cannot help (5-minute cache TTL).
- A statusline that becomes noticeably slower or flickers.

## Part 1: Statusline

### Target output

Calm state (last response 8 min ago, 84k context):

```
Opus 5.5 │ claude-statusline (main) │ ⏱ 1h12m │ ● high

context ████▒▒▒▒▒▒  42% ⟳ 84k/200k │ cache 52m
current ███▒▒▒▒▒▒▒  31% ⟳ 15:12 │ weekly ██▒▒▒▒▒▒▒▒  22% ⟳ Nov 12, 09:00
```

Hot state (cache about to expire, 5 h limit running ahead):

```
Opus 5.5 │ claude-statusline (main*) │ ⏱ 2h40m │ ● high

context ████████▒▒  78% ⟳ 156k/200k │ ⧗ cache 12m ♻
current ███████▒▒▒  73%↑ ⟳ 15:12 │ weekly ████▒▒▒▒▒▒  41% ⟳ Nov 12, 09:00
```

The `extra` usage line (when enabled) stays as today, on its own line(s), with the new bar.

### Bars

- Width 10, filled `█`, empty `▒` (empty part dim).
- Filled part colored by the existing `color_for_pct` thresholds (mint <50, orange <70,
  yellow <90, red ≥90).

### Cache segment (in the `context` line)

Source: the statusline stdin JSON field `prompt_cache` (Claude Code ≥ 2.1.251):
`warm`, `caching_observed`, `ttl` (`"5m"`/`"1h"`), `expires_at` (epoch seconds),
`recache_tokens_if_cold`.

- `prompt_cache` absent or `caching_observed == false` → no cache segment.
- `warm == false` or `expires_at` in the past → `cache cold`, dim.
- Otherwise remaining = `expires_at − now`, rendered in minutes (`52m`; `<1m` under a minute).
  - remaining > 25 min → white `cache 52m`
  - 5 min < remaining ≤ 25 min → yellow `⧗ cache 12m`
  - remaining ≤ 5 min → red `⧗ cache 3m`
- With a 5 m TTL the same rules apply (it will just always be ≤ 5 min → red while warm).
  *Builder's call:* for `ttl == "5m"` it is fine to use proportional thresholds instead if
  red-all-the-time looks bad; keep it simple.
- `♻` suffix when keep-alive is active for this session (see Part 2, state handoff).

### Pace arrow `↑`

For each window (`five_hour` = 5 h, `seven_day` = 7 d), from the usage API response:

```
window_start = resets_at − window_length
elapsed_pct  = (now − window_start) / window_length × 100
arrow if used_pct − elapsed_pct ≥ 10
```

Printed right after the percentage (`73%↑`), same color as the percentage. Applies to both
`current` and `weekly`.

### Refresh while idle

The installer sets `statusLine.refreshInterval` (seconds) so the countdown ticks while idle.
Value: 30. (`git status --porcelain` and `jq` run on each tick — do not go lower.)

The installer's "already configured" check currently compares only `type` and `command`;
it must also compare `refreshInterval` so existing installs get updated.

### State handoff for Part 2

On each run the statusline writes a small per-session state file used by the keep-alive
hook:

`~/.claude/statusline-state/<session_id>.json`

```json
{ "updated_at": 1794229000, "ttl": "1h", "warm": true, "expires_at": 1794231000,
  "context_tokens": 156000, "context_size": 200000 }
```

plus `"five_hour_pct"` and `"seven_day_pct"` (from the usage API data, for the keep-alive
usage guard; omitted when unknown).

`session_id` comes from the statusline stdin JSON. Write atomically (temp file + `mv`).

## Part 2: Cache keep-alive

### Mechanism

Claude Code can schedule a recurring prompt inside the running session (session-scoped cron:
the `CronCreate` / `CronDelete` / `CronList` tools that back `/loop`). Jobs fire only when the
session is idle, which is exactly the case to cover. Each fire sends a tiny prompt; Claude
answers in one word; the request reads the whole conversation from cache, which refreshes the
1 h TTL.

Three pieces, all installed by `bin/install.js`:

1. **Skill** `~/.claude/skills/keepwarm/SKILL.md` — user-invocable as `/keepwarm` (start) and
   `/keepwarm off` (stop). Also invoked by Claude when the hook nudges it.
2. **Hook** `~/.claude/keepwarm-hook.sh`, registered under `hooks.UserPromptSubmit` in
   `~/.claude/settings.json`.
3. **Statusline** writes the state file (Part 1) and shows `♻`.

### Division of labor

**The hook owns all decisions and all file writes; Claude only calls the cron tools.**
Reason: file writes/`rm` outside the working directory need permission, and an unattended
ping turn must never stall on a permission dialog. `CronCreate` / `CronDelete` / `CronList`
need no permission. Every tool call in a ping turn is another full-cache API request, so the
ping turn must use zero tools except the one `CronDelete` on stop.

Session ID: available as `CLAUDE_CODE_SESSION_ID` in hook processes and as
`${CLAUDE_SESSION_ID}` substitution in SKILL.md — no need to pass it via `additionalContext`.

### Skill behavior

Start (`/keepwarm`, or after a hook nudge):
- If a keep-alive job already exists (`CronList`, prompt contains `[keepwarm]`) → say so,
  do nothing.
- Otherwise `CronCreate` a recurring job every 30 min, on off-minutes (e.g. `13,43 * * * *`),
  with prompt `[keepwarm] cache keep-alive ping`. Recurring 30-min jobs run a consistent
  0–15 min late, so gaps stay ~30 min, which keeps a 1 h cache warm with margin.
- No file writes (the hook handles markers).

Refusing to start (ttl, usage guard, …) is decided by the hook, which tells Claude via
`additionalContext` when the prompt is `/keepwarm` and starting is not allowed.

On each `[keepwarm]` fire, Claude follows what the hook injected:
- verdict `stop` → `CronDelete` the `[keepwarm]` job, reply `keepwarm stopped`.
- otherwise reply only `ok`. No tools.

Stop (`/keepwarm off`): `CronDelete` the `[keepwarm]` job(s), confirm.

### Hook behavior (`UserPromptSubmit`)

Stdin: `session_id`, `prompt`, … (no context size — that comes from the statusline state file).
Cron-fired prompts DO go through `UserPromptSubmit`.

1. **Ping** — `prompt` *contains* `[keepwarm]` (substring, not prefix — the fired prompt may
   arrive wrapped). Not user input; never update `.last-input`.
   - If now − `.last-input` ≥ 4 h, or state `ttl != "1h"`, or the usage guard trips →
     remove `.keepwarm` marker, inject `additionalContext`: verdict `stop` (CronDelete the
     job, reply `keepwarm stopped`).
   - Else if now − `.last-input` < 30 min (user is active; cache is warm anyway) →
     `decision: "block"` — the ping never reaches the API, zero cost. (Leaves a block notice
     in the transcript; acceptable.)
   - Else → touch `.keepwarm` marker, inject verdict `ok` (reply only `ok`, no tools).
2. **`/keepwarm off`** → update `.last-input`, remove `.keepwarm` marker.
3. **`/keepwarm`** → update `.last-input`; if start is not allowed (ttl, usage guard) inject the
   reason so Claude refuses; else create `.keepwarm` marker.
4. **Any other prompt** → update `.last-input`. Then nudge if: state file exists,
   `ttl == "1h"`, `context_tokens ≥ 50000`, no `.keepwarm` marker, not yet nudged in this
   session (`.nudged`), usage guard OK → inject `additionalContext` telling Claude to run the
   `keepwarm` skill; create `.nudged` and `.keepwarm` markers.
5. Output is JSON with `hookSpecificOutput.additionalContext` (`hookEventName:
   "UserPromptSubmit"`). Fast: no network, only `jq` + file reads. Never block a non-ping
   prompt; on any error exit 0.

**Build gate:** before shipping, verify empirically (local Claude Code 2.1.319) what
`prompt` the hook receives for a cron fire, so the `[keepwarm]` match is proven. If it fails,
pings would refresh `.last-input` and the job would run until cron's 7-day expiry — a direct
violation of the 4 h anti-goal.

**Usage guard** (decided by the user): trips when `five_hour_pct ≥ 90` or
`seven_day_pct ≥ 90` in the state file. Keep-alive does not start, and a running one stops.
Missing values → guard does not trip.

**Parallel sessions** (decided by the user): keep-alive is per session — each session meeting
the nudge rule gets its own. The ≥ 50k context threshold keeps quick one-off sessions out.

"User input" = every `UserPromptSubmit` except pings, including background-agent
report-backs (they mean the session is alive). *My call.*

### Costs (must be stated in README)

Each ping that reaches the API is one request reading the full context from cache (~0.1×
input price on the API; on a subscription it counts toward the 5 h / 7 d limits). Pings while
the user is active are blocked by the hook and cost nothing. Worst case per abandoned
session: ~8 pings over 4 h. Example: 150k-token context → 8 × 150k cache-read tokens ≈ cost
of one cold re-cache. So keep-alive pays off when the user comes back within 4 h and costs at
most ~one re-cache when they don't.

README note: Claude Code's built-in idle compaction (1 h-TTL sessions ≥ 200k tokens idle ~1 h)
is suppressed while keep-alive runs. No upper context bound on the nudge. *My call.*

### Cleanup

- Marker / state files older than 7 days in `~/.claude/statusline-state/` may be deleted by
  the statusline opportunistically (cheap `find -mtime +7 -delete`, at most once per day).
- Cron jobs die with the session; stale `.keepwarm` markers only affect `♻`. The statusline
  shows `♻` only if the marker exists **and** the state file was refreshed by this session
  (same session ID), so a dead session never shows it.

## Installer changes (`bin/install.js`)

- Copy `statusline.sh` (as today), `keepwarm-hook.sh` (chmod 755), and the skill directory.
- `settings.json`: set `statusLine` incl. `refreshInterval`; add the hook entry to
  `hooks.UserPromptSubmit` without touching other hooks; idempotent (no duplicate entry on
  re-install).
- Uninstall: remove the hook entry (only ours), hook script, skill directory, state directory;
  existing statusline restore behavior unchanged.
- README: document the cache segment, `↑`, keep-alive (`/keepwarm`, `/keepwarm off`,
  auto-start rule, 4 h cut-off, costs), minimum Claude Code version 2.1.251.

## Decided by the user

- Keep the current multi-line layout; line 1 unchanged.
- Block bars; `current` + `weekly` on one line; cache info in the `context` line.
- Cache segment always visible (dim), colored only when expiry is near (option A).
- Keep-alive: up to 4 h without user input, then let the cache go cold.
- Keep-alive should start automatically when it makes sense; manual command too.
- Ships as part of this package via the installer.
- Usage guard at 90 % of the 5 h or 7 d limit.
- Keep-alive per session (users typically run 2–3 long sessions in parallel).
- Package renamed to the user's own npm scope. *My call on the exact name:*
  `@kocour/claude-statusline` (matches the GitHub owner); `author` and README `npx` commands
  updated accordingly; keep the upstream MIT license and credit the original author in README.

## My calls (builder may revise with reason)

- Thresholds: cache yellow ≤ 25 min, red ≤ 5 min; pace arrow at +10 points; auto-nudge at
  ≥ 50k context tokens; ping every 30 min; `refreshInterval` 30 s.
- Data from `prompt_cache` stdin field rather than parsing the transcript.
- Hook ↔ statusline handoff via per-session files in `~/.claude/statusline-state/`.
- Hook decides and writes files; Claude only calls cron tools; pings during active use are
  blocked at zero cost.
- Nudge at most once per session.
- `♻` marker for active keep-alive.

## Left to the builder

- Exact shell structure, helper names, file naming inside the package (e.g. `bin/keepwarm-hook.sh`,
  `skills/keepwarm/SKILL.md`), and the skill's wording.
- Portability details (macOS `date -j` vs GNU `date`, as already handled in the script).
- Testing approach: feed sample stdin JSON to `statusline.sh` / the hook and assert output.
