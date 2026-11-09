#!/bin/bash
# Tests for bin/keepwarm-hook.sh (UserPromptSubmit hook).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/keepwarm-hook.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
export HOME="$TMP/home"
NOW=1767268800
SID="sess-1"

fresh() { rm -rf "$TMP/state"; mkdir -p "$TMP/state"; export STATUSLINE_STATE_DIR="$TMP/state"; }

# state_file <ttl> <expires_at> <context_tokens> [five_hour_pct] [seven_day_pct]
state_file() {
    jq -n --arg ttl "$1" --argjson exp "$2" --argjson ctx "$3" --arg fh "${4:-}" --arg sd "${5:-}" '
        {updated_at: 0, ttl: $ttl, warm: true, expires_at: $exp, context_tokens: $ctx, context_size: 200000}
        + (if $fh != "" then {five_hour_pct: ($fh|tonumber)} else {} end)
        + (if $sd != "" then {seven_day_pct: ($sd|tonumber)} else {} end)' > "$TMP/state/$SID.json"
}

# run_hook <prompt> [now]: prints stdout; exit code must be 0
run_hook() {
    local out rc
    out=$(jq -n --arg s "$SID" --arg p "$1" '{session_id:$s, prompt:$p}' \
        | KEEPWARM_NOW="${2:-$NOW}" bash "$HOOK"); rc=$?
    [ "$rc" -eq 0 ] || echo "NONZERO_EXIT:$rc"
    printf '%s' "$out"
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

test_user_prompt_updates_last_input() {
    fresh
    local out; out=$(run_hook "hello")
    assert_eq "" "$out" "no stdout"
    assert_eq "$NOW" "$(cat "$TMP/state/$SID.last-input")" "last-input is now"
}

test_nudge_large_session() {
    fresh; state_file 1h $((NOW + 3000)) 156000
    local out; out=$(run_hook "hello")
    local ctx; ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
    assert_contains "$ctx" "keepwarm: this session has 156k" "nudge text"
    assert_eq "UserPromptSubmit" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "event name"
    [ -f "$TMP/state/$SID.nudged" ] && _pass || _fail ".nudged exists"
    [ -f "$TMP/state/$SID.keepwarm" ] && _pass || _fail ".keepwarm exists"
}

test_nudge_only_once() {
    fresh; state_file 1h $((NOW + 3000)) 156000
    run_hook "hello" >/dev/null
    rm -f "$TMP/state/$SID.keepwarm"
    assert_eq "" "$(run_hook "again")" "second prompt silent"
}

test_no_nudge_small_context() {
    fresh; state_file 1h $((NOW + 3000)) 40000
    assert_eq "" "$(run_hook "hello")" "small context silent"
}

test_no_nudge_ttl_5m() {
    fresh; state_file 5m $((NOW + 200)) 156000
    assert_eq "" "$(run_hook "hello")" "5m ttl silent"
}

test_no_nudge_guard() {
    fresh; state_file 1h $((NOW + 3000)) 156000 92
    assert_eq "" "$(run_hook "hello")" "guard silent"
}

test_no_nudge_without_state() {
    fresh
    assert_eq "" "$(run_hook "hello")" "no state silent (and exit 0)"
}

test_ping_ok() {
    fresh
    local real; real=$(date +%s)
    state_file 1h $((real + 600)) 100000
    printf '%s' $((real - 3600)) > "$TMP/state/$SID.last-input"
    local out; out=$(run_hook "[keepwarm] cache keep-alive ping" "$real")
    assert_contains "$out" "keepwarm verdict: ok" "verdict ok"
    assert_eq "$((real - 3600))" "$(cat "$TMP/state/$SID.last-input")" "last-input unchanged"
    local m; m=$(mtime "$TMP/state/$SID.keepwarm")
    [ $((m - real)) -le 5 ] && [ $((real - m)) -le 5 ] && _pass || _fail "keepwarm mtime near now ($m vs $real)"
}

test_ping_blocked_when_warm() {
    fresh; state_file 1h $((NOW + 3000)) 100000
    printf '%s' $((NOW - 600)) > "$TMP/state/$SID.last-input"
    local out; out=$(run_hook "[keepwarm] ping")
    assert_contains "$out" '"decision":"block"' "blocked"
    assert_contains "$out" "keepwarm: cache still warm, ping skipped" "block reason"
    local real; real=$(date +%s)
    printf '%s' $((real - 600)) > "$TMP/state/$SID.last-input"
    state_file 1h $((real + 3000)) 100000
    run_hook "[keepwarm] ping" "$real" >/dev/null
    local m; m=$(mtime "$TMP/state/$SID.keepwarm")
    [ $((m - real)) -le 5 ] && [ $((real - m)) -le 5 ] && _pass || _fail "blocked ping touches keepwarm ($m vs $real)"
}

test_ping_stop_after_4h() {
    fresh; state_file 1h $((NOW + 600)) 100000
    printf '%s' $((NOW - 14400)) > "$TMP/state/$SID.last-input"
    touch "$TMP/state/$SID.keepwarm"
    local out; out=$(run_hook "[keepwarm] ping")
    assert_contains "$out" "keepwarm verdict: stop (no user input for 4h)" "stop 4h"
    [ ! -e "$TMP/state/$SID.keepwarm" ] && _pass || _fail ".keepwarm removed"
}

test_ping_stop_ttl() {
    fresh; state_file 5m $((NOW + 100)) 100000
    printf '%s' $((NOW - 600)) > "$TMP/state/$SID.last-input"
    assert_contains "$(run_hook "[keepwarm] ping")" "stop (cache TTL is not 1h)" "stop ttl"
}

test_ping_stop_guard() {
    fresh; state_file 1h $((NOW + 100)) 100000 10 90
    printf '%s' $((NOW - 600)) > "$TMP/state/$SID.last-input"
    assert_contains "$(run_hook "[keepwarm] ping")" "stop (plan usage above 90%)" "stop guard"
}

test_ping_without_last_input_stops() {
    fresh; state_file 1h $((NOW + 100)) 100000
    assert_contains "$(run_hook "[keepwarm] ping")" "stop (no record of user input)" "stop no record"
}

test_ping_marker_inside_wrapped_prompt() {
    fresh; state_file 1h $((NOW + 600)) 100000
    printf '%s' $((NOW - 3600)) > "$TMP/state/$SID.last-input"
    local out; out=$(run_hook $'<scheduled-task>\n[keepwarm] cache keep-alive ping\n</scheduled-task>')
    assert_contains "$out" "keepwarm verdict: ok" "wrapped ping recognised"
    assert_eq "$((NOW - 3600))" "$(cat "$TMP/state/$SID.last-input")" "last-input unchanged"
}

test_keepwarm_command_start() {
    fresh
    local out; out=$(run_hook "/keepwarm")
    assert_eq "" "$out" "no stdout"
    [ -f "$TMP/state/$SID.keepwarm" ] && _pass || _fail ".keepwarm exists"
}

test_keepwarm_command_refused() {
    fresh; state_file 1h $((NOW + 3000)) 100000 95
    local out; out=$(run_hook "/keepwarm")
    assert_contains "$out" "keepwarm: do not start keep-alive (plan usage above 90%)" "refused"
    [ ! -e "$TMP/state/$SID.keepwarm" ] && _pass || _fail ".keepwarm not created"
}

test_keepwarm_command_refused_ttl() {
    fresh; state_file 5m $((NOW + 100)) 100000
    assert_contains "$(run_hook "/keepwarm")" "keepwarm: do not start keep-alive (cache TTL is not 1h)" "refused ttl"
}

test_keepwarm_off() {
    fresh
    touch "$TMP/state/$SID.keepwarm"
    local out; out=$(run_hook "/keepwarm off")
    assert_eq "" "$out" "no stdout"
    [ ! -e "$TMP/state/$SID.keepwarm" ] && _pass || _fail ".keepwarm removed"
    [ -f "$TMP/state/$SID.nudged" ] && _pass || _fail ".nudged created"
}

test_garbage_stdin() {
    fresh
    local out rc
    out=$(printf 'not json' | KEEPWARM_NOW=$NOW bash "$HOOK"); rc=$?
    assert_eq 0 "$rc" "exit 0"
    assert_eq "" "$out" "no stdout"
}

test_invalid_session_id() {
    fresh
    local out rc
    out=$(jq -n '{session_id:"../evil", prompt:"hello"}' | KEEPWARM_NOW=$NOW bash "$HOOK"); rc=$?
    assert_eq 0 "$rc" "exit 0"
    assert_eq "" "$out" "no stdout"
    assert_eq 0 "$(find "$TMP/state" -type f | wc -l | tr -d ' ')" "no files written"
}

test_ping_unknown_ttl_ok() {
    fresh
    echo '{"ttl":null,"warm":false,"expires_at":null,"context_tokens":100000}' > "$TMP/state/$SID.json"
    printf '%s' $((NOW - 600)) > "$TMP/state/$SID.last-input"
    assert_contains "$(run_hook "[keepwarm] ping")" "keepwarm verdict: ok" "null ttl does not stop"
}

test_ping_missing_state_ok() {
    fresh
    printf '%s' $((NOW - 600)) > "$TMP/state/$SID.last-input"
    assert_contains "$(run_hook "[keepwarm] ping")" "keepwarm verdict: ok" "missing state does not stop"
}

test_newline_session_id() {
    fresh
    local out rc
    out=$(jq -n '{session_id:"ok\nping", prompt:"hello"}' | KEEPWARM_NOW=$NOW bash "$HOOK"); rc=$?
    assert_eq 0 "$rc" "exit 0"
    assert_eq "" "$out" "no stdout"
    assert_eq 0 "$(find "$TMP/state" -type f | wc -l | tr -d ' ')" "no files written"
}

test_string_pct_no_guard() {
    fresh
    echo '{"ttl":"1h","warm":true,"expires_at":null,"context_tokens":100000,"five_hour_pct":"92"}' > "$TMP/state/$SID.json"
    assert_contains "$(run_hook "hello")" "keepwarm: this session has 100k" "string pct ignored, nudge fires"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
report
