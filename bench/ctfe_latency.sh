#!/bin/sh
# Compile-time evaluation latency for bench/ctfe_bench.nim.
#
# `hastur test bench` answers "does it still compute the same number". This
# answers "how long did the compiler spend evaluating the consts", which is
# the number bench/ctfe_bench.nim actually exists for and which no golden file
# can hold. Three scenarios, each on the same nimcache in this order:
#
#   cold    a nimcache that does not exist yet: every const is a fresh
#           sub-compile, and the wall time divided by the const count is the
#           per-evaluation cost
#   warm    nothing changed: nifmake should find the whole graph up to date
#           and run no commands at all
#   edit    one line appended to a COPY of the benchmark, so nimsem re-runs
#           and re-reaches every const while the consts themselves are
#           unchanged. This is the memo's scenario and the one the dev loop
#           actually hits
#   forced  `-f`: the outer graph is rebuilt from scratch. The sub-programs
#           must not be rebuilt with it (they are content-addressed), so this
#           should cost the outer build plus one binary run per const
#
# The `nifmake-report` lines printed under each timing are the outer build's
# per-command counts; `total=0` twice is a build that did nothing.
#
# Usage: bench/ctfe_latency.sh [nimony-executable]
# Writes nothing outside its scratch directory.

set -e

root=$(cd "$(dirname "$0")/.." && pwd)
nimony=${1:-"$root/bin/nimony"}
work=${TMPDIR:-/tmp}/ctfe_latency.$$
cache="$work/nimcache"
src="$work/ctfe_bench.nim"

if [ ! -x "$nimony" ]; then
  echo "ctfe_latency: $nimony not found; run \`hastur build nimony\` first" >&2
  exit 1
fi

mkdir -p "$work"
cp "$root/bench/ctfe_bench.nim" "$src"
trap 'rm -rf "$work"' EXIT INT TERM

echo "ctfe_latency: $nimony"
echo

run() {
  label=$1
  shift
  echo "--- $label ---"
  start=$(date +%s.%N 2>/dev/null || date +%s)
  "$nimony" c --report --nimcache:"$cache" "$@" "$src" || exit 1
  end=$(date +%s.%N 2>/dev/null || date +%s)
  echo "$label wall: $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')s"
  echo
}

rm -rf "$cache"
run cold

# One `<sfx>.out.nif` per evaluation the compile had to perform, which is the
# divisor for the cold number and the count the memo has to keep at zero.
evals=$(ls "$cache" | grep -c '\.out\.nif$' || true)
echo "ctfe_latency: $evals sub-programs compiled and run"
echo

run warm

# A real statement, not a comment: nifler drops comments, so its `.p.nif` would
# be byte-identical and nimsem would never re-run — which is a different
# scenario (see `hastur test tests/incremental`, phase "touch"). Appended at
# the END so no line number above it moves: a `.p.nif` carries the line info of
# the bodies it inlines, so an edit that shifts the consts is a different
# program and every memo legitimately misses.
printf '\necho "ctfe_latency edit"\n' >> "$src"
run edit

run forced -f
