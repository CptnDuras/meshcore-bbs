#!/bin/sh
# Build the meshbbs daemon with the Boehm GC.
#
# IMPORTANT: do NOT add -prod. With -prod, V 0.5.2 silently ignores
# "-gc boehm" ("v3 currently supports only -gc none") and builds with no
# garbage collector at all. The ORM then leaks every query result, and the
# daemon (which polls the DB every second) grows ~450 MB/hour until the
# kernel OOM-kills it. Verified: 20k list_scheduled() calls peak at 1.4 GB
# without the GC and 9 MB with it.
set -eu
cd "$(dirname "$0")"
V="${V:-$HOME/projects/v/v}"
out="${1:-meshbbs.gc}"
"$V" -gc boehm -o "$out" bbs
if [ "$(strings "$out" | grep -c GC_malloc)" -eq 0 ]; then
    echo "build.sh: $out has no Boehm GC linked - refusing (check flags)" >&2
    rm -f "$out"; exit 1
fi
echo "built $out with Boehm GC"
