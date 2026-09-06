#!/bin/sh
# The fast-devloop progress benchmark (JIT.md 12, JIT_IMPL.md "Measuring").
#
# One script, one toolchain directory in, one table out — so the same numbers
# can be taken for the fork-point toolchain and for the current branch on the
# same machine in the same session, and any phase's claimed win is checked
# against the merged branch rather than against its own worktree.
#
# Scenarios (each timed `runs` times, median reported, raw runs kept):
#
#   hello.forced     hello world, `-f` on a warm nimcache (frontend + backend graphs)
#   hello.nochange   hello world, nothing changed (nifmake mtime walk only)
#   hello.edit       hello world, one appended statement, rebuild + relink
#   ctfe.cold        tests/nimony/consteval/tmyops.nim (5 consts) on a fresh nimcache
#   ctfe.warm        same, nothing changed
#   ctfe.edit        same, one appended statement: nimsem re-runs, every const memo-hit
#   ctfe.forced      same, `-f`: the outer graph rebuilt, sub-programs not
#   bench.cold       bench/ctfe_bench.nim (14 consts) on a fresh nimcache
#   bench.edit       same, one appended statement
#   stdlib.cold      tests/nimony/stdlib/tall.nim on a fresh nimcache (every std module)
#   stdlib.forced    same, `-f`
#   stdlib.edit      touch-edit lib/std/strutils.nim (a copy of the tree is NOT made:
#                    the edit is appended and reverted, so run this on a clean tree)
#
# Usage: bench/devloop_bench.sh <toolchain-root> [label] [runs]
#   <toolchain-root> is a checkout with bin/ and lib/ (nimony finds lib/ next
#   to its bin/). Tests and bench sources are taken from THIS checkout so both
#   toolchains compile identical inputs.
#
# Prints a table on stdout; everything else goes to a scratch directory that is
# removed on exit. Set KEEP=1 to keep it.

set -u

here=$(cd "$(dirname "$0")/.." && pwd)
root=${1:?"usage: devloop_bench.sh <toolchain-root> [label] [runs]"}
label=${2:-$(basename "$root")}
runs=${3:-3}
nimony="$root/bin/nimony"
work=${TMPDIR:-/tmp}/devloop_bench.$$
export NIMONY_VFS=${NIMONY_VFS:-disk}

if [ ! -x "$nimony" ]; then
  echo "devloop_bench: $nimony not found" >&2
  exit 1
fi
mkdir -p "$work"
if [ "${KEEP:-0}" != "1" ]; then trap 'rm -rf "$work"' EXIT INT TERM; fi

# runone <cmd...>: runs the command, prints "wall cpu" in seconds. cpu is the
# user+sys time of the command and every process it spawned (nifmake, the
# tools, cc, the CTFE sub-programs), which is what JIT.md 12 rule 5 asks for
# beside wall: under contention wall doubles while cpu-sum barely moves.
runone() {
  python3 - "$@" <<'PY'
import resource, subprocess, sys, time
t0 = time.time()
r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
p = subprocess.run(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
t1 = time.time()
r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
if p.returncode != 0:
    sys.stderr.write(p.stdout.decode(errors="replace")[-800:])
print(f"{t1 - t0:.3f} {cpu:.3f}")
PY
}

table="$work/table.txt"
: > "$table"

# measure <name> <n> <setup-shell> <cmd...>: setup, then cmd, n times.
measure() {
  name=$1; n=$2; setup=$3; shift 3
  walls=""; cpus=""
  i=0
  while [ $i -lt "$n" ]; do
    eval "$setup"
    set -- "$@"
    out=$(runone "$@") || echo "devloop_bench: $name failed" >&2
    walls="$walls ${out%% *}"
    cpus="$cpus ${out##* }"
    i=$((i+1))
  done
  medw=$(python3 -c "import statistics,sys; print(f'{statistics.median([float(x) for x in sys.argv[1:]]):.3f}')" $walls)
  medc=$(python3 -c "import statistics,sys; print(f'{statistics.median([float(x) for x in sys.argv[1:]]):.3f}')" $cpus)
  printf '%-15s wall %7s  cpu %7s   raw wall:%s  cpu:%s\n' "$name" "$medw" "$medc" "$walls" "$cpus" | tee -a "$table"
}

# ---- hello world -----------------------------------------------------------
hello="$work/hello.nim"
printf 'import std/syncio\necho "hello"\n' > "$hello"
hc="$work/nc_hello"
rm -rf "$hc"; "$nimony" c --silentMake --nimcache:"$hc" "$hello" >/dev/null 2>&1
measure hello.forced   "$runs" ":" "$nimony" c -f --silentMake --nimcache:"$hc" "$hello"
measure hello.nochange "$runs" ":" "$nimony" c --silentMake --nimcache:"$hc" "$hello"
measure hello.edit     "$runs" "printf 'echo \"edit\"\n' >> $hello" "$nimony" c --silentMake --nimcache:"$hc" "$hello"

# ---- CTFE: tmyops (5 consts) ------------------------------------------------
ctfe="$work/tmyops.nim"
cp "$here/tests/nimony/consteval/tmyops.nim" "$ctfe"
cc="$work/nc_ctfe"
measure ctfe.cold   "$runs" "rm -rf $cc" "$nimony" c --silentMake --nimcache:"$cc" "$ctfe"
measure ctfe.warm   "$runs" ":" "$nimony" c --silentMake --nimcache:"$cc" "$ctfe"
measure ctfe.edit   "$runs" "printf 'echo \"edit\"\n' >> $ctfe" "$nimony" c --silentMake --nimcache:"$cc" "$ctfe"
measure ctfe.forced "$runs" ":" "$nimony" c -f --silentMake --nimcache:"$cc" "$ctfe"

# ---- CTFE: bench/ctfe_bench.nim (14 consts) --------------------------------
if [ -f "$here/bench/ctfe_bench.nim" ]; then
  cb="$work/ctfe_bench.nim"
  cp "$here/bench/ctfe_bench.nim" "$cb"
  bc="$work/nc_bench"
  measure bench.cold "$runs" "rm -rf $bc" "$nimony" c --silentMake --nimcache:"$bc" "$cb"
  measure bench.edit "$runs" "printf 'echo \"edit\"\n' >> $cb" "$nimony" c --silentMake --nimcache:"$bc" "$cb"
fi

# ---- stdlib-wide: tall.nim -------------------------------------------------
tall="$here/tests/nimony/stdlib/tall.nim"
sc="$work/nc_stdlib"
measure stdlib.cold   "$runs" "rm -rf $sc" "$nimony" c --silentMake --nimcache:"$sc" "$tall"
measure stdlib.forced "$runs" ":" "$nimony" c -f --silentMake --nimcache:"$sc" "$tall"
# strutils edit: append a harmless proc to the TOOLCHAIN's copy (that is the one
# nimony compiles), rebuild, and restore the file byte for byte afterwards.
su="$root/lib/std/strutils.nim"
cp "$su" "$work/strutils.orig"
measure stdlib.edit "$runs" "printf '\nproc devloopBenchMarker*(): int = 1\n' >> $su" "$nimony" c --silentMake --nimcache:"$sc" "$tall"
cp "$work/strutils.orig" "$su"
# the trailing runs left tall's cache built against the edited strutils; leave it.

echo
echo "label: $label   toolchain: $root   runs: $runs (median)   NIMONY_VFS=$NIMONY_VFS"
