#!/bin/bash
# Shared test helpers. Source this file from *.test.sh files.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="$ROOT/bin/statusline.sh"
FAILS=0
PASSES=0

strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

_fail() { FAILS=$((FAILS + 1)); echo "FAIL: $1"; [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/    /'; }
_pass() { PASSES=$((PASSES + 1)); }

assert_eq() {
    if [ "$1" = "$2" ]; then _pass; else _fail "$3" "expected: $1
actual:   $2"; fi
}

assert_contains() {
    case "$1" in *"$2"*) _pass ;; *) _fail "$3" "missing: $2
in:
$1" ;; esac
}

assert_not_contains() {
    case "$1" in *"$2"*) _fail "$3" "unexpected: $2
in:
$1" ;; *) _pass ;; esac
}

# run_statusline <stdin-file>: runs the statusline with the current env,
# prints ANSI-stripped output.
run_statusline() {
    bash "$STATUSLINE" < "$1" | strip_ansi
    return "${PIPESTATUS[0]}"
}

# run_statusline_raw <stdin-file>: like run_statusline but keeps ANSI escapes.
run_statusline_raw() {
    bash "$STATUSLINE" < "$1"
    return "${PIPESTATUS[0]}"
}

# An undefined command inside a test must fail it, not pass silently.
# The handler runs in a forked shell, so it records the failure in a file.
LIB_FAIL_FILE=$(mktemp)
trap 'rm -f "$LIB_FAIL_FILE"' EXIT
command_not_found_handle() { echo "FAIL: undefined command: $1"; echo x >> "$LIB_FAIL_FILE"; return 127; }

report() {
    echo "$PASSES passed, $FAILS failed"
    [ ! -s "$LIB_FAIL_FILE" ] && [ "$FAILS" -eq 0 ] && [ $((PASSES + FAILS)) -gt 0 ]
}
