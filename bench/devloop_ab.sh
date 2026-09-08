#!/bin/sh
# Interleaved A/B of ONE scenario between two toolchains: A B A B ... so that
# slow drift (thermal state, a decaying load average, a background build that
# starts halfway) hits both sides equally. `devloop_bench.sh` runs each
# toolchain's whole table in one block, which is fine for a 2x signal and
# useless for a 5 % one; this is the tool for the 5 % question.
#
# Usage: bench/devloop_ab.sh <toolchain-A> <toolchain-B> [scenario] [rounds]
#   scenario: stdlib.forced (default) | stdlib.cold | hello.forced | ctfe.forced
#             | self.editbody (a statement inserted into a called proc of sem.nim)
#             | self.editdead (a private, never-called proc appended: DCE removes it)
#             | self.editcall (a new proc AND a call to it from semStmt: the call graph changes)
#             | self.nochange (rebuild with nothing edited: the no-op floor)
#             | self.cold | self.run   (native backend; BACKEND=c for the C path)
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
rss = r1.ru_maxrss/(1<<20) if sys.platform=="darwin" else r1.ru_maxrss/1024
print(f"{t1-t0:.3f} {(r1.ru_utime-r0.ru_utime)+(r1.ru_stime-r0.ru_stime):.3f} {rss:.0f}")
PY
}

src=""; flags=""; prep=":"
case $scen in
  stdlib.forced) src="$here/tests/nimony/stdlib/tall.nim"; flags="-f" ;;
  stdlib.cold)   src="$here/tests/nimony/stdlib/tall.nim"; prep="rm -rf \$nc" ;;
  hello.forced)  src="$work/hello.nim"; printf 'import std/syncio\necho "hello"\n' > "$src"; flags="-f" ;;
  ctfe.forced)   src="$work/tmyops.nim"; cp "$here/tests/nimony/consteval/tmyops.nim" "$src"; flags="-f" ;;
  self.editbody|self.editdead|self.editcall|self.nochange|self.cold|self.run)
    # The compiler compiling itself (fork-point sources, copied per side) with
    # the native backend; `self.run` is `nimony r ... --version`.
    selfsrc=${SELF_SRC:-/tmp/devloop_base/src}
    for side in A B; do mkdir -p "$work/self_$side" "$work/out_$side"; cp -R "$selfsrc" "$work/self_$side/src"; done
    src="src/nimony/nimony.nim" ;;
  *) echo "unknown scenario $scen" >&2; exit 1 ;;
esac
backend=${BACKEND:-n}

# One command per side and scenario. The self.* scenarios run under `cd` into
# that side's source copy, so the toolchain path must be absolute (it is:
# `A`/`B` are resolved below).
A=$(cd "$A" && pwd); B=$(cd "$B" && pwd)
cmdfor() {  # cmdfor <side> <nc> -> prints the command line
  eval "t=\$$1"
  case $scen in
    self.editbody|self.editdead|self.editcall) echo "cd $work/self_$1 && $t/bin/nimony $backend --silentMake --nimcache:$2 --out:$work/out_$1/nimony $src" ;;
    self.nochange|self.cold) echo "cd $work/self_$1 && $t/bin/nimony $backend --silentMake --nimcache:$2 --out:$work/out_$1/nimony $src" ;;
    self.run)      echo "cd $work/self_$1 && $t/bin/nimony r --silentMake --nimcache:$2 $src --version" ;;
    *)             echo "$t/bin/nimony $backend --silentMake $flags --nimcache:$2 $src" ;;
  esac
}
case $scen in
  # A LIVE edit: a statement inserted into the body of a proc every compile
  # calls (`semStmt`), so the change reaches hexer, arkham, DCE and the link.
  # The earlier form appended a private, never-called proc, which DCE deleted
  # -- arkham and nifasm measured 0 s on it (notes/b3b.md §10).
  self.editbody) prep='sed -i "" "/^proc semStmt\*(c: var SemContext; dest: var TokenBuf; n: var Cursor; isNewScope: bool) =\$/a\\
  if isNewScope: discard $i
" $work/self_$side/src/nimony/sem.nim' ;;
  self.editdead) prep='printf "\nproc devloopBenchBody$i(): int = 1\n" >> $work/self_$side/src/nimony/sem.nim' ;;
  # A live edit that also changes the CALL GRAPH every round: a new private
  # proc, and a call to it from `semStmt`. That is what re-runs `dceLive`
  # (whose input, the module's `.dce.nif`, does not change for a body-only
  # edit after the first round -- notes/h1.md).
  self.editcall) prep='sed -i "" "/^proc semStmt\*(c: var SemContext; dest: var TokenBuf; n: var Cursor; isNewScope: bool) =\$/i\\
proc devloopCall$i(x: int): int = x + $i
" $work/self_$side/src/nimony/sem.nim; sed -i "" "/^proc semStmt\*(c: var SemContext; dest: var TokenBuf; n: var Cursor; isNewScope: bool) =\$/a\\
  if isNewScope: discard devloopCall$i($i)
" $work/self_$side/src/nimony/sem.nim' ;;
  self.run)      prep='printf "\nproc devloopBenchBody$i(): int = 1\n" >> $work/self_$side/src/nimony/sem.nim' ;;
  # Nothing edited at all: the floor a warm no-op rebuild costs.
  self.nochange) prep=':' ;;
  self.cold)     prep='rm -rf $nc' ;;
esac

# warm both caches once so a forced/edit scenario starts from the same state
for side in A B; do
  nc="$work/nc_$side"
  sh -c "$(cmdfor $side $nc)" >/dev/null 2>&1
done

wa=""; ca=""; wb=""; cb=""; ra=""; rb=""
i=0
while [ $i -lt "$rounds" ]; do
  for side in A B; do
    eval "t=\$$side"; nc="$work/nc_$side"
    eval "$prep"
    out=$(runone sh -c "$(cmdfor $side $nc)")
    set -- $out
    printf 'round %d  %s  wall %s  cpu %s  rss %sMB\n' "$i" "$side" "$1" "$2" "$3"
    if [ $side = A ]; then wa="$wa $1"; ca="$ca $2"; ra="$ra $3"; else wb="$wb $1"; cb="$cb $2"; rb="$rb $3"; fi
  done
  i=$((i+1))
done
python3 - "$scen" "$wa" "$ca" "$ra" "$wb" "$cb" "$rb" <<'PY'
import statistics, sys
scen, wa, ca, ra, wb, cb, rb = sys.argv[1], *[[float(x) for x in s.split()] for s in sys.argv[2:]]
def s(xs): return f"median {statistics.median(xs):.3f}  min {min(xs):.3f}"
print(f"{scen}: A wall {s(wa)} | cpu {s(ca)} | peak rss {statistics.median(ra):.0f} MB")
print(f"{scen}: B wall {s(wb)} | cpu {s(cb)} | peak rss {statistics.median(rb):.0f} MB")
print(f"B/A cpu (median): {statistics.median(cb)/statistics.median(ca):.3f}   B/A cpu (min): {min(cb)/min(ca):.3f}   B/A peak rss: {statistics.median(rb)/statistics.median(ra):.2f}")
PY
