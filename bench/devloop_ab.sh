#!/bin/sh
# Interleaved A/B of ONE scenario between two toolchains: A B A B ... so that
# slow drift (thermal state, a decaying load average, a background build that
# starts halfway) hits both sides equally. `devloop_bench.sh` runs each
# toolchain's whole table in one block, which is fine for a 2x signal and
# useless for a 5 % one; this is the tool for the 5 % question.
#
# Usage: bench/devloop_ab.sh <toolchain-A> <toolchain-B> [scenario] [rounds]
#   scenario: stdlib.forced (default) | stdlib.cold | hello.forced | ctfe.forced
# Prints per-round wall/cpu for both, then median and min of each.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
A=${1:?}; B=${2:?}; scen=${3:-stdlib.forced}; rounds=${4:-5}
work=${TMPDIR:-/tmp}/devloop_ab.$$; mkdir -p "$work"; trap 'rm -rf "$work"' EXIT INT TERM
export NIMONY_VFS=${NIMONY_VFS:-disk}

runone() { python3 - "$@" <<'PY'
import resource, subprocess, sys, time
t0=time.time(); r0=resource.getrusage(resource.RUSAGE_CHILDREN)
p=subprocess.run(sys.argv[1:],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
t1=time.time(); r1=resource.getrusage(resource.RUSAGE_CHILDREN)
print(f"{t1-t0:.3f} {(r1.ru_utime-r0.ru_utime)+(r1.ru_stime-r0.ru_stime):.3f}")
PY
}

src=""; flags=""; prep=":"
case $scen in
  stdlib.forced) src="$here/tests/nimony/stdlib/tall.nim"; flags="-f" ;;
  stdlib.cold)   src="$here/tests/nimony/stdlib/tall.nim"; prep="rm -rf \$nc" ;;
  hello.forced)  src="$work/hello.nim"; printf 'import std/syncio\necho "hello"\n' > "$src"; flags="-f" ;;
  ctfe.forced)   src="$work/tmyops.nim"; cp "$here/tests/nimony/consteval/tmyops.nim" "$src"; flags="-f" ;;
  *) echo "unknown scenario $scen" >&2; exit 1 ;;
esac

# warm both caches once so a forced/edit scenario starts from the same state
for side in A B; do
  eval "t=\$$side"; nc="$work/nc_$side"
  "$t/bin/nimony" c --silentMake --nimcache:"$nc" "$src" >/dev/null 2>&1
done

wa=""; ca=""; wb=""; cb=""
i=0
while [ $i -lt "$rounds" ]; do
  for side in A B; do
    eval "t=\$$side"; nc="$work/nc_$side"
    eval "$prep"
    out=$(runone "$t/bin/nimony" c --silentMake $flags --nimcache:"$nc" "$src")
    printf 'round %d  %s  wall %s  cpu %s\n' "$i" "$side" "${out%% *}" "${out##* }"
    if [ $side = A ]; then wa="$wa ${out%% *}"; ca="$ca ${out##* }"; else wb="$wb ${out%% *}"; cb="$cb ${out##* }"; fi
  done
  i=$((i+1))
done
python3 - "$scen" "$wa" "$ca" "$wb" "$cb" <<'PY'
import statistics, sys
scen, wa, ca, wb, cb = sys.argv[1], *[[float(x) for x in s.split()] for s in sys.argv[2:]]
def s(xs): return f"median {statistics.median(xs):.3f}  min {min(xs):.3f}"
print(f"{scen}: A wall {s(wa)} | cpu {s(ca)}")
print(f"{scen}: B wall {s(wb)} | cpu {s(cb)}")
print(f"B/A cpu (median): {statistics.median(cb)/statistics.median(ca):.3f}   B/A cpu (min): {min(cb)/min(ca):.3f}")
PY
