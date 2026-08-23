#!/bin/sh
# Runs the parity program on every tier and reports whether the three
# transcripts agree byte for byte.
#
#   GOS_PGSQL_TEST_URL='host=/var/run/postgresql dbname=gos_pgsql_test' \
#       tests/parity/run.sh
set -e
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

gos run . > "$out/vm.txt"
gos build . >/dev/null
./target/debug/pgsql-gos-parity > "$out/jit.txt"
gos build --release . >/dev/null
./target/release/pgsql-gos-parity > "$out/aot.txt"

if diff -u "$out/vm.txt" "$out/jit.txt" && diff -u "$out/vm.txt" "$out/aot.txt"; then
    echo "parity: the three tiers agree ($(wc -l < "$out/vm.txt") lines)"
else
    echo "parity: the tiers disagree" >&2
    exit 1
fi
