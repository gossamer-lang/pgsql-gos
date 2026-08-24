#!/bin/sh
# Formatting and lint, over the driver and every example. No server needed.
#
#   ./quick-check.sh          report only
#   ./quick-check.sh --fix    rewrite what `gos fmt` and `gos lint --fix` can
set -e
cd "$(dirname "$0")"

fix=no
[ "$1" = "--fix" ] && fix=yes

status=0

run() {
    label=$1
    shift
    if "$@" >/tmp/quick-check.$$ 2>&1; then
        printf '  ok    %s\n' "$label"
    else
        printf '  FAIL  %s\n' "$label"
        sed 's/^/        /' /tmp/quick-check.$$
        status=1
    fi
    rm -f /tmp/quick-check.$$
}

if [ "$fix" = yes ]; then
    echo "driver"
    run "fmt"  gos fmt .
    run "lint" gos lint --fix .
else
    echo "driver"
    run "fmt"  gos fmt --check .
    run "lint" gos lint .
fi

for dir in examples/*/ tests/integration tests/parity; do
    [ -f "$dir/project.toml" ] || continue
    name=${dir%/}
    echo "$name"
    if [ "$fix" = yes ]; then
        ( cd "$name" && gos fmt . >/dev/null 2>&1 ) && printf '  ok    fmt\n' || { printf '  FAIL  fmt\n'; status=1; }
        ( cd "$name" && gos lint --fix . >/dev/null 2>&1 ) && printf '  ok    lint\n' || { printf '  FAIL  lint\n'; status=1; }
    else
        ( cd "$name" && gos fmt --check . >/dev/null 2>&1 ) && printf '  ok    fmt\n' || { printf '  FAIL  fmt\n'; status=1; }
        ( cd "$name" && gos lint . >/dev/null 2>&1 ) && printf '  ok    lint\n' || { printf '  FAIL  lint\n'; status=1; }
    fi
done

if [ "$status" -eq 0 ]; then
    echo
    echo "quick-check: clean"
else
    echo
    echo "quick-check: something needs attention" >&2
fi
exit "$status"
