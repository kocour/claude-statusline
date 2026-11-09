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

test_context_bar_blocks
test_limits_on_one_line
test_no_dots
test_no_usage_data
report
