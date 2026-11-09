# Compact Statusline + Cache Keep-Alive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the statusline more compact with a prompt-cache countdown and pace arrow, and add an auto-starting, self-stopping prompt-cache keep-alive (hook + skill), all installed by `bin/install.js`.

**Architecture:** `bin/statusline.sh` renders the lines and, on every run, writes a per-session state file. `bin/keepwarm-hook.sh` (a `UserPromptSubmit` hook) reads that state file plus its own `.last-input` timestamps, makes every keep-alive decision, writes all marker files, and tells Claude what to do via `additionalContext` or blocks pings. `skills/keepwarm/SKILL.md` only makes Claude call the session cron tools.

**Tech Stack:** bash + jq (scripts), Node.js ≥ 18 built-ins only (installer, `node:test`), plain bash test scripts.

**Spec:** `docs/superpowers/specs/2026-11-09-compact-statusline-cache-keepalive-design.md`

## Global Constraints

- Minimum Claude Code version: 2.1.251 (needed for `prompt_cache` in statusline stdin).
- Line 1 of the statusline is unchanged.
- Bars: width 10, filled `█`, empty `▒` (empty dim), colored by existing `color_for_pct`.
- Cache thresholds: > 25 min dim `cache Nm`; 5 < r ≤ 25 min yellow `⧗ cache Nm`; ≤ 5 min red `⧗ cache Nm`; cold → dim `cache cold`.
- Pace arrow when `used_pct − elapsed_pct ≥ 10`; windows 5 h and 7 d.
- `statusLine.refreshInterval` = 30.
- State dir: `~/.claude/statusline-state/` (override env `STATUSLINE_STATE_DIR`, used by tests).
- Keep-alive: ping marker `[keepwarm]` (substring match), cron every 30 min on off-minutes, stop after 4 h without user input, usage guard at ≥ 90 % of 5 h or 7 d, nudge at ≥ 50000 context tokens and `ttl == "1h"`, at most one nudge per session, per-session keep-alive.
- Package name `@kocour/claude-statusline`; keep MIT license, credit upstream author (Kamran Ahmed) in README.
- Everything in the repo in English. Commit messages without any attribution trailers.
- No runtime dependencies beyond jq, curl, git, node.

## Review Focus

1. Cron-fired prompt arrives wrapped/prefixed → `[keepwarm]` must still match (substring), else pings count as user input and never stop. Test: `test_ping_marker_inside_wrapped_prompt` (Task 5); empirical gate in Task 8.
2. Missing/partial stdin fields (`prompt_cache` absent, `caching_observed:false`, `expires_at:null`, no `session_id`) → statusline must still render and not write a broken state file. Tests in Task 2/4.
3. Missing `.last-input` or state file during a ping → must stop (never ping indefinitely). Test: `test_ping_without_last_input_stops` (Task 5).
4. Re-running the installer on an existing install, or a settings.json with other users' hooks → no duplicate hook entry, foreign hooks untouched, `refreshInterval` added to an old config. Tests in Task 7.
5. Usage data missing (no OAuth token / curl failed) → no pace arrow, usage guard does not trip, limits line omitted as today. Tests in Task 3/5.

---

## File Structure

- Modify `bin/statusline.sh` — rendering + state file write + cleanup.
- Create `bin/keepwarm-hook.sh` — UserPromptSubmit hook, all keep-alive decisions.
- Create `skills/keepwarm/SKILL.md` — `/keepwarm`, `/keepwarm off`, ping handling.
- Modify `bin/install.js` — install/uninstall of all three + settings merge.
- Modify `package.json` — name, author, `files`, `scripts.test`.
- Modify `README.md`.
- Create `test/lib.sh` (assert helpers, ANSI strip), `test/statusline.test.sh`, `test/keepwarm-hook.test.sh`, `test/install.test.js`, `test/run.sh`, `test/fixtures/*.json`.

Test seams (env vars, only for tests, documented in script headers):
- `STATUSLINE_NOW` — epoch used as "now" in statusline.sh; `KEEPWARM_NOW` in the hook.
- `STATUSLINE_USAGE_FILE` — if set, statusline reads usage JSON from this file and never calls curl.
- `STATUSLINE_STATE_DIR` — state dir for both scripts.

---

### Task 1: Test harness, block bars, limits on one line

**Files:**
- Create: `test/lib.sh`, `test/run.sh`, `test/statusline.test.sh`, `test/fixtures/stdin-basic.json`, `test/fixtures/usage-basic.json`
- Modify: `bin/statusline.sh` (`build_bar`, usage fetch, rate-lines block), `package.json` (`"scripts": {"test": "bash test/run.sh"}`)

**Interfaces:**
- Produces: `test/lib.sh` functions `strip_ansi` (stdin→stdout), `assert_eq <expected> <actual> <name>`, `assert_contains <haystack> <needle> <name>`, `assert_not_contains …`, `run_statusline <stdin-file>` (runs `bin/statusline.sh` with current env, prints ANSI-stripped output). `test/run.sh` runs every `test/*.test.sh` and `node --test test/`, exits non-zero on any failure.
- Produces: env seams `STATUSLINE_NOW`, `STATUSLINE_USAGE_FILE`, `STATUSLINE_STATE_DIR` honored by `statusline.sh`.

Fixtures: `stdin-basic.json` — `model.display_name "Opus 5.5"`, `cwd` = a temp non-git dir set by the test, `context_window.context_window_size 200000`, `current_usage` summing to 84000, `session_id "test-session"`. `usage-basic.json` — `five_hour.utilization 31`, `seven_day.utilization 22`, `resets_at` ISO values chosen relative to a fixed `STATUSLINE_NOW` so elapsed ≈ 50 % (no arrow), `extra_usage.is_enabled false`.

- [ ] **Step 1: Write failing tests** in `test/statusline.test.sh`:
  - `test_context_bar_blocks`: output contains `context ████▒▒▒▒▒▒  42% ⟳ 84k/200k`.
  - `test_limits_on_one_line`: one line matches `^current ███▒▒▒▒▒▒▒  31% ⟳ [0-9]{2}:[0-9]{2} │ weekly ██▒▒▒▒▒▒▒▒  22% ⟳ ` and there is no line starting with `weekly`.
  - `test_no_dots`: output contains neither `●` nor `○` in lines 3+ (line 1 effort icon `●` is allowed).
  - `test_no_usage_data`: with `STATUSLINE_USAGE_FILE` pointing to a missing file → no `current` line, `context` line still present, exit 0.
- [ ] **Step 2: Run** `bash test/run.sh` — Expected: FAIL on the three rendering tests.
- [ ] **Step 3: Implement**: `build_bar` uses `█`/`▒` (empty dimmed); usage source = `STATUSLINE_USAGE_FILE` if set (no curl), else existing cache/curl path; `current` and `weekly` printed on one line joined by `${sep}`; extra-usage lines unchanged except new bar; `now` comes from `${STATUSLINE_NOW:-$(date +%s)}` everywhere time is used (session duration included).
- [ ] **Step 4: Run** `bash test/run.sh` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Use block bars and show current and weekly limits on one line"`

### Task 2: Cache countdown segment

**Files:**
- Modify: `bin/statusline.sh`
- Test: `test/statusline.test.sh`, fixtures `test/fixtures/stdin-cache-*.json` (or build stdin with `jq` in the test from `stdin-basic.json`)

**Interfaces:**
- Consumes: Task 1 helpers and seams.
- Produces: shell function `render_cache_segment` (reads globals parsed from stdin `prompt_cache.*` and `now`; prints the segment incl. leading ` │ ` or nothing). Variable `keepwarm_active` (`true`/`false`) is consulted for the ` ♻` suffix — Task 4 sets it; default `false`.

- [ ] **Step 1: Write failing tests** (all with `STATUSLINE_NOW=1794229000`, `caching_observed true`, `ttl "1h"`, `warm true` unless stated):
  - `test_cache_dim_when_far`: `expires_at = now+3120` → context line ends with `│ cache 52m`, and raw (non-stripped) output has no yellow/red escape before `cache`.
  - `test_cache_yellow`: `expires_at = now+720` → ends with `│ ⧗ cache 12m`, raw contains yellow `\033[38;2;230;200;0m` before `⧗`.
  - `test_cache_red`: `expires_at = now+180` → `│ ⧗ cache 3m`, raw contains red `\033[38;2;255;85;85m`.
  - `test_cache_under_minute`: `expires_at = now+30` → `⧗ cache <1m`.
  - `test_cache_cold_warm_false`: `warm false` → ends with `│ cache cold`.
  - `test_cache_cold_expired`: `expires_at = now-10` → `│ cache cold`.
  - `test_cache_hidden_not_observed`: `caching_observed false` → context line has no `cache`.
  - `test_cache_hidden_absent`: no `prompt_cache` key → no `cache`, exit 0.
  - `test_cache_null_expires`: `warm true`, `expires_at null` → `cache cold`.
- [ ] **Step 2: Run** `bash test/run.sh` — Expected: new tests FAIL.
- [ ] **Step 3: Implement `render_cache_segment`** per thresholds in Global Constraints; minutes = `floor(remaining/60)`; `<1m` when remaining < 60 s. Parse all `prompt_cache` fields with one `jq` call.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Show prompt cache countdown in the context line"`

### Task 3: Pace arrow

**Files:**
- Modify: `bin/statusline.sh`
- Test: `test/statusline.test.sh`, `test/fixtures/usage-ahead.json`

**Interfaces:**
- Produces: function `pace_arrow <used_pct> <resets_at_iso> <window_seconds>` → prints `↑` or nothing. Window seconds: `18000` (5 h), `604800` (7 d).

Algorithm (from spec): `window_start = resets_at − window`; `elapsed_pct = (now − window_start) * 100 / window`; arrow iff `used_pct − elapsed_pct ≥ 10`. Integer math is fine.

- [ ] **Step 1: Write failing tests:**
  - `test_pace_arrow_five_hour`: 5 h `utilization 73`, `resets_at` = now + 3 h (elapsed 40 %) → line contains ` 73%↑ ⟳`.
  - `test_pace_no_arrow_boundary`: utilization 49, elapsed 40 % → no `↑` (difference 9).
  - `test_pace_arrow_exact_boundary`: utilization 50, elapsed 40 % → `↑`.
  - `test_pace_arrow_weekly`: 7 d utilization 41, elapsed ≈ 20 % → `weekly` part contains `41%↑`.
  - `test_pace_bad_reset`: `resets_at` missing/null → no arrow, no error output on stderr.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement `pace_arrow`** and append its output after the `%` for both windows, same color as the percentage.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Show pace arrow when plan usage runs ahead of the clock"`

### Task 4: State file, keep-alive indicator, cleanup

**Files:**
- Modify: `bin/statusline.sh`
- Test: `test/statusline.test.sh`

**Interfaces:**
- Produces (consumed by Task 5): `$STATE_DIR/<session_id>.json`, written atomically (temp file in same dir + `mv`):
  `{"updated_at":<epoch>,"ttl":"1h"|"5m"|null,"warm":bool,"expires_at":<epoch|null>,"context_tokens":<int>,"context_size":<int>,"five_hour_pct":<int, omitted if unknown>,"seven_day_pct":<int, omitted if unknown>}`
  where `STATE_DIR=${STATUSLINE_STATE_DIR:-$HOME/.claude/statusline-state}`.
- Consumes (written by Task 5): `$STATE_DIR/<session_id>.keepwarm`. `keepwarm_active=true` iff that file exists and its mtime ≥ now − 3000 s (50 min).

- [ ] **Step 1: Write failing tests:**
  - `test_state_file_written`: after a run, `jq` on `$STATE_DIR/test-session.json` gives `ttl "1h"`, `context_tokens 84000`, `five_hour_pct 31`, `seven_day_pct 22`, `updated_at == STATUSLINE_NOW`.
  - `test_state_file_no_usage`: no usage data → `five_hour_pct` key absent.
  - `test_state_no_session_id`: stdin without `session_id` → no file written, output still rendered.
  - `test_keepwarm_indicator`: fresh `test-session.keepwarm` (touch) with warm cache → context line ends with `♻`.
  - `test_keepwarm_indicator_stale`: marker with mtime 2 h ago (`touch -t`) → no `♻`.
  - `test_cleanup_old_files`: a file in `$STATE_DIR` with mtime 8 days ago is deleted; one with mtime 1 day ago remains; cleanup runs at most once per day, tracked by `$STATE_DIR/.last-cleanup` mtime.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** state write (build with `jq -n`), marker check, cleanup (`find "$STATE_DIR" -type f -mtime +7 -delete` when `.last-cleanup` missing or older than 1 day). Note `touch`/`stat` portability (macOS `stat -f %m`, GNU `stat -c %Y`) — reuse the pattern already in the script.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Write per-session state file for keep-alive and show its indicator"`

### Task 5: Keep-alive hook

**Files:**
- Create: `bin/keepwarm-hook.sh`
- Test: `test/keepwarm-hook.test.sh`

**Interfaces:**
- Consumes: Task 4 state file format.
- Produces (stdin JSON from Claude Code: `session_id`, `prompt`): files in `$STATE_DIR`: `<sid>.last-input` (content: epoch), `<sid>.keepwarm` (marker, mtime = liveness), `<sid>.nudged` (marker). Stdout: nothing, or one JSON object. Always exit 0.
- Output shapes:
  - context: `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<text>"}}`
  - block: `{"decision":"block","reason":"keepwarm: cache still warm, ping skipped"}`
- Exact texts (tests match on the leading token):
  - ping ok: `keepwarm verdict: ok. Reply with exactly "ok". Do not use any tools.`
  - ping stop: `keepwarm verdict: stop (<reason>). Use CronList to find the job whose prompt contains [keepwarm], CronDelete it, then reply "keepwarm stopped". Use no other tools.` — reasons: `no user input for 4h`, `cache TTL is not 1h`, `plan usage above 90%`, `no record of user input`.
  - start refused: `keepwarm: do not start keep-alive (<reason>). Tell the user why in one sentence.`
  - nudge: `keepwarm: this session has <N>k tokens of context on the 1h prompt cache. Before answering, invoke the keepwarm skill to start the cache keep-alive, then handle the user's message normally.`

Decision logic (spec "Hook behavior", with one refinement — see note):

```
now = KEEPWARM_NOW or date +%s; sid from stdin; no sid → exit 0
guard_trips = five_hour_pct ≥ 90 or seven_day_pct ≥ 90   (missing → false)
if prompt contains "[keepwarm]":                       # ping
    last = <sid>.last-input  (missing → stop "no record of user input")
    if now-last ≥ 14400 → stop "no user input for 4h"
    elif state.ttl != "1h" → stop "cache TTL is not 1h"   (state missing → treat as unknown, do not stop on ttl)
    elif guard_trips → stop "plan usage above 90%"
    elif state.expires_at - now > 2400 → block            # cache survives until next ping + margin
    else touch <sid>.keepwarm; ok
    on stop: rm -f <sid>.keepwarm
else:
    write now → <sid>.last-input
    if prompt starts with "/keepwarm off" → rm -f <sid>.keepwarm; no output
    elif prompt starts with "/keepwarm" → if ttl known and != "1h" or guard_trips → start refused; else touch <sid>.keepwarm
    elif state exists, ttl=="1h", context_tokens ≥ 50000, no <sid>.keepwarm, no <sid>.nudged, not guard_trips
         → nudge; touch <sid>.nudged and <sid>.keepwarm
```

Note (refinement of the spec's "last-input < 30 min → block"): blocking on `expires_at − now > 2400` (40 min) is equivalent in intent (user active → cache warm → ping not needed) but measured on the cache itself, so a blocked ping can never let the cache expire before the next ping 30 min later.

- [ ] **Step 1: Write failing tests** (each test gets a fresh temp `STATUSLINE_STATE_DIR`, fixed `KEEPWARM_NOW`, writes a state file via `jq -n`):
  - `test_user_prompt_updates_last_input`: prompt `hello` → `.last-input` == now, no stdout.
  - `test_nudge_large_session`: state ttl 1h, context_tokens 156000 → stdout `additionalContext` starts with `keepwarm: this session has 156k`; `.nudged` and `.keepwarm` exist.
  - `test_nudge_only_once`: second prompt → no stdout.
  - `test_no_nudge_small_context`: context_tokens 40000 → no stdout.
  - `test_no_nudge_ttl_5m`: ttl 5m → no stdout.
  - `test_no_nudge_guard`: five_hour_pct 92 → no stdout.
  - `test_no_nudge_without_state`: no state file → no stdout, exit 0.
  - `test_ping_ok`: last-input now−3600, expires_at now+600 → `keepwarm verdict: ok`; `.last-input` unchanged; `.keepwarm` mtime == now-ish.
  - `test_ping_blocked_when_warm`: expires_at now+3000 → stdout `"decision":"block"`.
  - `test_ping_stop_after_4h`: last-input now−14400 → `keepwarm verdict: stop (no user input for 4h)`, `.keepwarm` removed.
  - `test_ping_stop_ttl`: ttl 5m → `stop (cache TTL is not 1h)`.
  - `test_ping_stop_guard`: seven_day_pct 90 → `stop (plan usage above 90%)`.
  - `test_ping_without_last_input_stops`: no `.last-input` → `stop (no record of user input)`.
  - `test_ping_marker_inside_wrapped_prompt`: prompt `<scheduled-task>\n[keepwarm] cache keep-alive ping\n</scheduled-task>` → treated as ping (last-input unchanged).
  - `test_keepwarm_command_start`: prompt `/keepwarm` → `.keepwarm` exists, no stdout.
  - `test_keepwarm_command_refused`: prompt `/keepwarm`, five_hour_pct 95 → `keepwarm: do not start keep-alive (plan usage above 90%)`.
  - `test_keepwarm_off`: prompt `/keepwarm off` → `.keepwarm` removed.
  - `test_garbage_stdin`: stdin `not json` → exit 0, no stdout.
- [ ] **Step 2: Run** `bash test/run.sh` — Expected: FAIL (script missing).
- [ ] **Step 3: Implement `bin/keepwarm-hook.sh`** (bash, `jq`, no network; build output JSON with `jq -n --arg`; every failure path exits 0).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Add UserPromptSubmit hook that drives the cache keep-alive"`

### Task 6: Keep-alive skill

**Files:**
- Create: `skills/keepwarm/SKILL.md`
- Test: `test/keepwarm-hook.test.sh` (add a static check)

**Interfaces:**
- Consumes: hook texts from Task 5 (`keepwarm verdict: ok|stop`, `keepwarm: do not start`, nudge).
- Produces: user-invocable skill `keepwarm` (argument `off` optional).

Content requirements (wording is the builder's):
- Frontmatter: `name: keepwarm`; `description` saying it keeps the 1 h prompt cache warm while the user is away, used for `/keepwarm`, `/keepwarm off`, and when a `keepwarm:` hook message asks for it.
- Start: if the hook said `do not start` → explain in one sentence, stop. `CronList`; if a job whose prompt contains `[keepwarm]` exists → say it is already running. Else `CronCreate` with `cron: "13,43 * * * *"`, `recurring: true`, `prompt: "[keepwarm] cache keep-alive ping"`. Confirm in one line incl. "stops by itself after 4 h without your input". No file operations, ever.
- `off`: `CronList` → `CronDelete` every job with `[keepwarm]` in the prompt → confirm in one line.
- Ping turn (prompt contains `[keepwarm]`): obey the `keepwarm verdict` in context exactly; with no verdict present reply `ok` and use no tools.
- After a nudge: start keep-alive as above, then continue with the user's actual message.

- [ ] **Step 1: Write failing test** `test_skill_file_contract`: `skills/keepwarm/SKILL.md` exists, frontmatter has `name: keepwarm`, body contains `13,43 * * * *`, `[keepwarm] cache keep-alive ping`, `CronDelete`, `keepwarm verdict`.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Write `skills/keepwarm/SKILL.md`.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Add keepwarm skill"`

### Task 7: Installer, package metadata

**Files:**
- Modify: `bin/install.js`, `package.json`
- Test: `test/install.test.js` (`node:test`, runs `node bin/install.js` with `HOME` set to a temp dir; `os.homedir()` honors `HOME`)

**Interfaces:**
- Consumes: `bin/statusline.sh`, `bin/keepwarm-hook.sh`, `skills/keepwarm/`.
- Produces in `$HOME/.claude/`: `statusline.sh`, `keepwarm-hook.sh` (mode 755), `skills/keepwarm/SKILL.md`; `settings.json`:
  - `statusLine = {"type":"command","command":"bash \"$HOME/.claude/statusline.sh\"","refreshInterval":30}`
  - `hooks.UserPromptSubmit` contains exactly one entry `{"hooks":[{"type":"command","command":"bash \"$HOME/.claude/keepwarm-hook.sh\""}]}`. "Ours" = any hook whose `command` contains `keepwarm-hook.sh`.

- [ ] **Step 1: Write failing tests:**
  - `install creates all files and settings`: files exist, hook executable, settings match the values above.
  - `install is idempotent`: running twice → one keepwarm entry in `hooks.UserPromptSubmit`.
  - `install preserves foreign hooks`: pre-existing `hooks.UserPromptSubmit` entry with another command and a `hooks.Stop` entry → both still present after install.
  - `install upgrades old statusLine config`: existing `statusLine` without `refreshInterval` → gets `refreshInterval: 30`.
  - `uninstall removes ours only`: after install + `--uninstall`: hook script, `skills/keepwarm`, `statusline-state/` gone; foreign hooks remain; no empty `hooks.UserPromptSubmit` array or empty `hooks` object left; statusline backup restore behavior unchanged.
- [ ] **Step 2: Run** `node --test test/` — Expected: FAIL.
- [ ] **Step 3: Implement** in `install.js` (helpers `installKeepwarm(settings)`, `uninstallKeepwarm(settings)`; the "already configured" check compares `refreshInterval` too). `package.json`: `name "@kocour/claude-statusline"`, `author "Lukas Kocourek"`, `files ["bin","skills"]`, keep `bin` entry.
- [ ] **Step 4: Run** `bash test/run.sh` — Expected: all PASS.
- [ ] **Step 5: Commit** `git commit -m "Install keepwarm hook and skill, set statusline refresh interval"`

### Task 8: README + empirical gate

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README** (English): `npx @kocour/claude-statusline`; requirement Claude Code ≥ 2.1.251; what each segment means (cache countdown colors, `♻`, `↑`); keep-alive section: auto-start rule (≥ 50k tokens, 1 h cache, once per session), `/keepwarm`, `/keepwarm off`, stops after 4 h without input or at ≥ 90 % of a limit, per-session, dies with the session; costs paragraph from the spec (ping = full-context cache read, counts toward plan limits, ~8 pings worst case ≈ one cold re-cache, active-use pings are blocked at zero cost); note that keep-alive suppresses built-in idle compaction; credit "Based on claude-statusline by Kamran Ahmed" with link to upstream. Replace the demo image reference only if a new screenshot is provided; otherwise leave it.
- [ ] **Step 2: Commit** `git commit -m "Document cache countdown and keep-alive"`
- [ ] **Step 3: Empirical gate (orchestrator + user, interactive — not a subagent):** run `node bin/install.js`; temporarily add `printf '%s\n' "$prompt" >> "$STATE_DIR/debug-prompts.log"` at the top of the installed `~/.claude/keepwarm-hook.sh`; in a fresh interactive Claude Code session ask Claude to `CronCreate` a one-shot job in 2 minutes with prompt `[keepwarm] cache keep-alive ping`; wait. Expected: the log contains a line with `[keepwarm]` and `.last-input` did not change at the fire. Then run `/keepwarm` and `/keepwarm off` once each and check the reply and `CronList`. Remove the debug line (re-run installer). If the marker is not found in the fired prompt, stop and fix Task 5's match before merging.
