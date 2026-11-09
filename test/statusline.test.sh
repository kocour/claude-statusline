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

test_context_bar_blocks
test_limits_on_one_line
test_no_dots
test_no_usage_data
report
