#!/bin/bash
# Runs all shell tests (test/*.test.sh) and node tests (test/*.test.js).
cd "$(dirname "$0")/.." || exit 1
rc=0
for t in test/*.test.sh; do
    [ -e "$t" ] || continue
    echo "== $t"
    bash "$t" || rc=1
done
shopt -s nullglob
js=(test/*.test.js)
if [ ${#js[@]} -gt 0 ]; then
    echo "== node --test"
    node --test "${js[@]}" || rc=1
fi
exit $rc
