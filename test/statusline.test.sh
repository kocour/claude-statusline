#!/bin/bash
# Tests for bin/statusline.sh rendering.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.claude" "$TMP/cwd" "$TMP/state"
export HOME="$TMP/home"
export STATUSLINE_STATE_DIR="$TMP/state"
export STATUSLINE_NOW=1767268800
export STATUSLINE_USAGE_FILE="$ROOT/test/fixtures/usage-basic.json"
unset CLAUDE_CODE_OAUTH_TOKEN

STDIN="$TMP/stdin.json"
sed "s#__CWD__#$TMP/cwd#" "$ROOT/test/fixtures/stdin-basic.json" > "$STDIN"

test_context_bar_blocks() {
    local out; out=$(run_statusline "$STDIN")
    assert_contains "$out" "context ████▒▒▒▒▒▒  42% ⟳ 84k/200k" "context bar uses blocks"
}

test_limits_on_one_line() {
    local out; out=$(run_statusline "$STDIN")
    local n
    n=$(printf '%s\n' "$out" | grep -cE '^current ███▒▒▒▒▒▒▒  31% ⟳ [0-9]{2}:[0-9]{2} │ weekly ██▒▒▒▒▒▒▒▒  22% ⟳ ')
    assert_eq 1 "$n" "current and weekly share one line"
    n=$(printf '%s\n' "$out" | grep -c '^weekly')
    assert_eq 0 "$n" "no separate weekly line"
}

test_no_dots() {
    local out; out=$(run_statusline "$STDIN" | tail -n +3)
    assert_not_contains "$out" "●" "no filled dots in lines 3+"
    assert_not_contains "$out" "○" "no empty dots in lines 3+"
}

test_no_usage_data() {
    local out rc
    out=$(STATUSLINE_USAGE_FILE="$TMP/missing.json" run_statusline "$STDIN"); rc=$?
    assert_eq 0 "$rc" "exit 0 without usage data"
    assert_not_contains "$out" "current" "no current line without usage"
    assert_contains "$out" "context" "context line still present"
}

# ── cache countdown ─────────────────────────────────────
CNOW=1794229000
# make_cache_stdin <observed> <warm> <expires_at|null> : writes $TMP/cache.json
make_cache_stdin() {
    jq --argjson o "$1" --argjson w "$2" --argjson e "$3" \
        '.prompt_cache = {caching_observed: $o, warm: $w, expires_at: $e, ttl: "1h"}' \
        "$STDIN" > "$TMP/cache.json"
}
context_line() { printf '%s\n' "$1" | grep '^context'; }

test_cache_dim_when_far() {
    make_cache_stdin true true $((CNOW + 3120))
    local out raw
    out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    raw=$(STATUSLINE_NOW=$CNOW run_statusline_raw "$TMP/cache.json" | grep 'context')
    assert_eq "1" "$(context_line "$out" | grep -c '│ cache 52m$')" "far cache is plain dim countdown"
    local before="${raw%%cache*}"
    assert_not_contains "$before" $'\033[38;2;230;200;0m' "no yellow before cache"
    assert_not_contains "$before" $'\033[38;2;255;85;85m' "no red before cache"
}

test_cache_yellow() {
    make_cache_stdin true true $((CNOW + 720))
    local out raw
    out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    raw=$(STATUSLINE_NOW=$CNOW run_statusline_raw "$TMP/cache.json" | grep 'context')
    assert_eq "1" "$(context_line "$out" | grep -c '│ ⧗ cache 12m$')" "yellow cache text"
    assert_contains "${raw%%⧗*}" $'\033[38;2;230;200;0m' "yellow before hourglass"
}

test_cache_red() {
    make_cache_stdin true true $((CNOW + 180))
    local out raw
    out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    raw=$(STATUSLINE_NOW=$CNOW run_statusline_raw "$TMP/cache.json" | grep 'context')
    assert_eq "1" "$(context_line "$out" | grep -c '│ ⧗ cache 3m$')" "red cache text"
    assert_contains "${raw%%⧗*}" $'\033[38;2;255;85;85m' "red before hourglass"
}

test_cache_under_minute() {
    make_cache_stdin true true $((CNOW + 30))
    local out; out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    assert_contains "$out" "⧗ cache <1m" "under a minute"
}

test_cache_cold_warm_false() {
    make_cache_stdin true false $((CNOW + 3000))
    local out; out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    assert_eq "1" "$(context_line "$out" | grep -c '│ cache cold$')" "warm false is cold"
}

test_cache_cold_expired() {
    make_cache_stdin true true $((CNOW - 10))
    local out; out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    assert_eq "1" "$(context_line "$out" | grep -c '│ cache cold$')" "expired is cold"
}

test_cache_hidden_not_observed() {
    make_cache_stdin false true $((CNOW + 3000))
    local out; out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    assert_not_contains "$(context_line "$out")" "cache" "hidden when not observed"
}

test_cache_hidden_absent() {
    local out rc
    out=$(STATUSLINE_NOW=$CNOW run_statusline "$STDIN"); rc=$?
    assert_eq 0 "$rc" "exit 0 without prompt_cache"
    assert_not_contains "$(context_line "$out")" "cache" "hidden when absent"
}

test_cache_null_expires() {
    make_cache_stdin true true null
    local out; out=$(STATUSLINE_NOW=$CNOW run_statusline "$TMP/cache.json")
    assert_contains "$(context_line "$out")" "cache cold" "null expires_at is cold"
}

test_cache_dim_when_far
test_cache_yellow
test_cache_red
test_cache_under_minute
test_cache_cold_warm_false
test_cache_cold_expired
test_cache_hidden_not_observed
test_cache_hidden_absent
test_cache_null_expires

# ── pace arrow ──────────────────────────────────────────
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# make_usage <5h_util> <5h_reset_iso|""> <7d_util> <7d_reset_iso|""> : writes $TMP/usage.json
make_usage() {
    jq -n --argjson f "$1" --arg fr "$2" --argjson s "$3" --arg sr "$4" '
        {five_hour: ({utilization: $f} + (if $fr == "" then {} else {resets_at: $fr} end)),
         seven_day: ({utilization: $s} + (if $sr == "" then {} else {resets_at: $sr} end)),
         extra_usage: {is_enabled: false}}' > "$TMP/usage.json"
}
limits_line() { printf '%s\n' "$1" | grep '^current'; }

test_pace_arrow_five_hour() {
    make_usage 73 "$(iso_at $((STATUSLINE_NOW + 10800)))" 10 "$(iso_at $((STATUSLINE_NOW + 302400)))"
    local out; out=$(TZ=UTC STATUSLINE_USAGE_FILE="$TMP/usage.json" run_statusline "$STDIN")
    assert_contains "$(limits_line "$out")" " 73%↑ ⟳" "arrow after 5h percentage"
}

test_pace_no_arrow_boundary() {
    make_usage 49 "$(iso_at $((STATUSLINE_NOW + 10800)))" 10 "$(iso_at $((STATUSLINE_NOW + 302400)))"
    local out; out=$(TZ=UTC STATUSLINE_USAGE_FILE="$TMP/usage.json" run_statusline "$STDIN")
    assert_not_contains "$out" "↑" "diff 9 has no arrow"
}

test_pace_arrow_exact_boundary() {
    make_usage 50 "$(iso_at $((STATUSLINE_NOW + 10800)))" 10 "$(iso_at $((STATUSLINE_NOW + 302400)))"
    local out; out=$(TZ=UTC STATUSLINE_USAGE_FILE="$TMP/usage.json" run_statusline "$STDIN")
    assert_contains "$out" "50%↑" "diff 10 has arrow"
}

test_pace_arrow_weekly() {
    make_usage 10 "$(iso_at $((STATUSLINE_NOW + 10800)))" 41 "$(iso_at $((STATUSLINE_NOW + 483840)))"
    local out; out=$(TZ=UTC STATUSLINE_USAGE_FILE="$TMP/usage.json" run_statusline "$STDIN")
    local line; line=$(limits_line "$out")
    assert_contains "${line#*weekly}" "41%↑" "weekly arrow"
    assert_not_contains "${line%%weekly*}" "↑" "no 5h arrow"
}

test_pace_bad_reset() {
    make_usage 90 "" 90 ""
    local out err
    out=$(TZ=UTC STATUSLINE_USAGE_FILE="$TMP/usage.json" run_statusline "$STDIN" 2>"$TMP/err")
    err=$(cat "$TMP/err")
    assert_not_contains "$out" "↑" "missing reset has no arrow"
    assert_eq "" "$err" "no stderr output"
}

test_pace_future_reset_no_arrow() {
    make_usage 5 "$(iso_at $((STATUSLINE_NOW + 21600)))" 5 "$(iso_at $((STATUSLINE_NOW + 604800 + 86400)))"
    local out; out=$(TZ=UTC STATUSLINE_USAGE_FILE="$TMP/usage.json" run_statusline "$STDIN")
    assert_not_contains "$out" "↑" "reset beyond window gives no arrow"
}

test_pace_arrow_five_hour
test_pace_future_reset_no_arrow
test_pace_no_arrow_boundary
test_pace_arrow_exact_boundary
test_pace_arrow_weekly
test_pace_bad_reset

test_context_bar_blocks
test_limits_on_one_line
test_no_dots
test_no_usage_data
report
