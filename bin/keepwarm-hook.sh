#!/bin/bash
# UserPromptSubmit hook driving the prompt-cache keep-alive.
# Reads {session_id, prompt} on stdin; may print one JSON object; always exits 0.
# Test seams (tests only):
#   KEEPWARM_NOW           epoch used as "now"
#   STATUSLINE_STATE_DIR   state directory
set -f
trap 'exit 0' ERR

NOW="${KEEPWARM_NOW:-$(date +%s)}"
STATE_DIR="${STATUSLINE_STATE_DIR:-$HOME/.claude/statusline-state}"

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

# One jq parse: session id + prompt classification (ping | off | start | other).
parsed=$(printf '%s' "$input" | jq -r '
    (.session_id // "") as $s
    | (.prompt // "" | if type == "string" then . else "" end) as $p
    | [ (if ($s | type) == "string" and ($s | test("\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z")) then $s else "" end),
        (if ($p | contains("[keepwarm]")) then "ping"
         elif ($p | test("^\\s*/keepwarm\\s+off(\\s|$)")) then "off"
         elif ($p | test("^\\s*/keepwarm(\\s|$)")) then "start"
         else "other" end) ] | .[]' 2>/dev/null) || exit 0
sid=$(printf '%s\n' "$parsed" | sed -n 1p)
kind=$(printf '%s\n' "$parsed" | sed -n 2p)

[[ "$sid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 0
[ -n "$kind" ] || exit 0

STATE="$STATE_DIR/$sid.json"
LAST="$STATE_DIR/$sid.last-input"
KEEP="$STATE_DIR/$sid.keepwarm"
NUDGED="$STATE_DIR/$sid.nudged"

# One jq parse of the state file; "-" marks an unknown value.
have_state=0 ttl="-" expires="-" ctx="-" guard=0
if [ -f "$STATE" ]; then
    st=$(jq -r '
        [ (.ttl // "-"), (.expires_at // "-"), (.context_tokens // "-"),
          (if (((.five_hour_pct | numbers) // 0) >= 90 or ((.seven_day_pct | numbers) // 0) >= 90) then 1 else 0 end) ]
        | map(tostring) | .[]' "$STATE" 2>/dev/null) || st=""
    if [ -n "$st" ]; then
        have_state=1
        ttl=$(printf '%s\n' "$st" | sed -n 1p)
        expires=$(printf '%s\n' "$st" | sed -n 2p)
        ctx=$(printf '%s\n' "$st" | sed -n 3p)
        guard=$(printf '%s\n' "$st" | sed -n 4p)
    fi
fi
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

emit_context() {
    jq -nc --arg t "$1" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$t}}'
}

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

stop_reason=""
if [ "$kind" = "ping" ]; then
    last=""
    [ -f "$LAST" ] && last=$(tr -dc '0-9' < "$LAST")
    if ! is_int "$last"; then
        stop_reason="no record of user input"
    elif [ $((NOW - last)) -ge 14400 ]; then
        stop_reason="no user input for 4h"
    elif [ "$have_state" = 1 ] && [ "$ttl" != "-" ] && [ "$ttl" != "1h" ]; then
        stop_reason="cache TTL is not 1h"
    elif [ "$guard" = 1 ]; then
        stop_reason="plan usage above 90%"
    elif is_int "$expires" && [ $((expires - NOW)) -gt 2400 ]; then
        touch "$KEEP"
        jq -nc '{decision:"block",reason:"keepwarm: cache still warm, ping skipped"}'
        exit 0
    else
        touch "$KEEP"
        emit_context 'keepwarm verdict: ok. Reply with exactly "ok". Do not use any tools.'
        exit 0
    fi
    rm -f "$KEEP"
    emit_context "keepwarm verdict: stop ($stop_reason). Use CronList to find the job whose prompt contains [keepwarm], CronDelete it, then reply \"keepwarm stopped\". Use no other tools."
    exit 0
fi

# Real user input.
printf '%s' "$NOW" > "$LAST"

case "$kind" in
off)
    rm -f "$KEEP"
    touch "$NUDGED"
    ;;
start)
    if [ "$have_state" = 1 ] && [ "$ttl" != "-" ] && [ "$ttl" != "1h" ]; then
        emit_context "keepwarm: do not start keep-alive (cache TTL is not 1h). Tell the user why in one sentence."
    elif [ "$guard" = 1 ]; then
        emit_context "keepwarm: do not start keep-alive (plan usage above 90%). Tell the user why in one sentence."
    else
        touch "$KEEP"
    fi
    ;;
*)
    if [ "$have_state" = 1 ] && [ "$ttl" = "1h" ] && is_int "$ctx" && [ "$ctx" -ge 50000 ] \
        && [ ! -e "$KEEP" ] && [ ! -e "$NUDGED" ] && [ "$guard" != 1 ]; then
        touch "$NUDGED" "$KEEP"
        emit_context "keepwarm: this session has $((ctx / 1000))k tokens of context on the 1h prompt cache. Before answering, invoke the keepwarm skill to start the cache keep-alive, then handle the user's message normally."
    fi
    ;;
esac
exit 0
