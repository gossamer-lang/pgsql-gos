#!/bin/sh
# Checks and runs every example against a real server.
#
# An example that does not run is documentation that has stopped being true,
# so CI runs all of them rather than only compiling them. Each one owns its
# tables and drops them, so a run leaves nothing behind.
#
#   GOS_PGSQL_URL='host=/var/run/postgresql dbname=gos_pgsql_test' \
#       examples/run-all.sh
set -e
cd "$(dirname "$0")"

# The service example serves forever unless it is asked to check itself.
args_for() {
    case "$1" in
        service) echo "--selftest" ;;
        *) echo "" ;;
    esac
}

for dir in */; do
    name=${dir%/}
    [ -f "$name/project.toml" ] || continue
    printf '\n=== %s ===\n' "$name"
    ( cd "$name" && gos check . >/dev/null && gos run . $(args_for "$name") )
done

printf '\nevery example ran\n'
