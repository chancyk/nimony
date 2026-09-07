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
#   hello.nrun       same edit, `nimony n -r`: rebuild, relink, exec the image
#   hello.run        same edit, `nimony r`: rebuild and run from memory, no
#                    image written and no linker run (JIT_IMPL.md B1)
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
#   self.cold        the compiler compiling itself (src/nimony/nimony.nim, 127 modules,
#                    debug), fresh nimcache -- the fork point's sources for BOTH toolchains
#   self.nochange    same, nothing changed
#   self.editbody    same, a PRIVATE proc appended to src/nimony/sem.nim: the module's
#                    interface is unchanged, so importers need not re-sem
#   self.nrun        same body edit, `nimony n -r ... --version`: rebuild,
#                    relink the whole image, exec it, print the version
#   self.run         same body edit, `nimony r ... --version`: rebuild and run
#                    the compiler out of the compiler's own memory. The pair
#                    self.nrun/self.run is what B1 is measured by; until B3's
#                    per-module code cache lands the whole-image assemble
#                    dominates both, so the difference is only the image write,
#                    the ad-hoc codesign and the exec
#   self.edit        same, an EXPORTED proc appended: every importer re-sems
#   self.forced      same, `-f`
#
# `*.run` is native by definition (`nimony r` IS the native backend), so those
# two rows ignore BACKEND and are skipped entirely on a toolchain that has no
# `r` command -- which is how the fork-point base is told apart from the head.
#
# Usage: bench/devloop_bench.sh <toolchain-root> [label] [runs]
#   <toolchain-root> is a checkout with bin/ and lib/ (nimony finds lib/ next
#   to its bin/). Tests and bench sources are taken from THIS checkout so both
#   toolchains compile identical inputs.
#
# EXTRA="<flags>" adds nimony flags to every compile (e.g. EXTRA=--ctfe:engine).
# Each row: median wall, cpu-sum of the process tree, and the peak resident
# size of the largest process in it (rss, MB) -- the memory the pipeline
# needs, base vs head, since an in-process pipeline concentrates work into one
# process that used to be spread over many.
# Prints a table on stdout; everything else goes to a scratch directory that is
# removed on exit. Set KEEP=1 to keep it.

set -u

here=$(cd "$(dirname "$0")/.." && pwd)
root=${1:?"usage: devloop_bench.sh <toolchain-root> [label] [runs]"}
# Absolute, always: the `self.*` scenarios run their command under `cd` into a
# scratch copy of the sources, so a relative root (`.`, which is what the
# measurement protocol in JIT_IMPL.md spells) would resolve `./bin/nimony`
# against the wrong directory and every `self.*` row would silently be the
# 5 ms of a failing `sh -c`.
root=$(cd "$root" && pwd)
label=${2:-$(basename "$root")}
runs=${3:-3}
nimony="$root/bin/nimony"
work=${TMPDIR:-/tmp}/devloop_bench.$$
export NIMONY_VFS=${NIMONY_VFS:-disk}
extra=${EXTRA:-}   # extra nimony flags for every compile, e.g. EXTRA=--ctfe:engine
# The backend: `n` (arkham + nifasm, no C compiler, no linker) is the dev
# workflow the plan is for and the default here; BACKEND=c measures the C path.
# The stdlib-wide scenarios stay on `c`: `tall.nim` imports `std/rawthreads`,
# which has no nimNoLibc implementation on this host yet (B0, native_status.md).
backend=${BACKEND:-n}

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
# ru_maxrss of RUSAGE_CHILDREN is the peak resident size of the LARGEST
# waited-for descendant (bytes on macOS, KiB on Linux): what the biggest
# process of the build needed, which is the number an in-process pipeline
# moves. It is not a sum over concurrent processes.
rss = r1.ru_maxrss / (1 << 20) if sys.platform == "darwin" else r1.ru_maxrss / 1024
if p.returncode != 0:
    sys.stderr.write(p.stdout.decode(errors="replace")[-800:])
print(f"{t1 - t0:.3f} {cpu:.3f} {rss:.0f}")
PY
}

table="$work/table.txt"
: > "$table"

# measure <name> <n> <setup-shell> <cmd...>: setup, then cmd, n times.
measure() {
  name=$1; n=$2; setup=$3; shift 3
  walls=""; cpus=""; rsss=""
  i=0
  while [ $i -lt "$n" ]; do
    eval "$setup"
    set -- "$@"
    out=$(runone "$@") || echo "devloop_bench: $name failed" >&2
    set -- $out
    walls="$walls $1"; cpus="$cpus $2"; rsss="$rsss $3"
    i=$((i+1))
  done
  medw=$(python3 -c "import statistics,sys; print(f'{statistics.median([float(x) for x in sys.argv[1:]]):.3f}')" $walls)
  medc=$(python3 -c "import statistics,sys; print(f'{statistics.median([float(x) for x in sys.argv[1:]]):.3f}')" $cpus)
  medr=$(python3 -c "import statistics,sys; print(f'{statistics.median([float(x) for x in sys.argv[1:]]):.0f}')" $rsss)
  printf '%-15s wall %7s  cpu %7s  rss %5sMB   raw wall:%s  cpu:%s  rss:%s\n' "$name" "$medw" "$medc" "$medr" "$walls" "$cpus" "$rsss" | tee -a "$table"
}

# ---- hello world -----------------------------------------------------------
hello="$work/hello.nim"
printf 'import std/syncio\necho "hello"\n' > "$hello"
hc="$work/nc_hello"
rm -rf "$hc"; "$nimony" $backend $extra --silentMake --nimcache:"$hc" "$hello" >/dev/null 2>&1
measure hello.forced   "$runs" ":" "$nimony" $backend $extra -f --silentMake --nimcache:"$hc" "$hello"
measure hello.nochange "$runs" ":" "$nimony" $backend $extra --silentMake --nimcache:"$hc" "$hello"
measure hello.edit     "$runs" "printf 'echo \"edit\"\n' >> $hello" "$nimony" $backend $extra --silentMake --nimcache:"$hc" "$hello"

# B1: the same edit, run two ways. `hasRun` is what keeps the fork-point
# toolchain (which has no `r`) from reporting a row of failures.
hasRun=0
if "$nimony" r --help >/dev/null 2>&1; then hasRun=1; fi
if [ "$hasRun" = "1" ]; then
  measure hello.nrun "$runs" "printf 'echo \"edit\"\n' >> $hello" "$nimony" n $extra -r --silentMake --nimcache:"$hc" "$hello"
  measure hello.run  "$runs" "printf 'echo \"edit\"\n' >> $hello" "$nimony" r $extra --silentMake --nimcache:"$hc" "$hello"
fi

# ---- CTFE: tmyops (5 consts) ------------------------------------------------
ctfe="$work/tmyops.nim"
cp "$here/tests/nimony/consteval/tmyops.nim" "$ctfe"
cc="$work/nc_ctfe"
measure ctfe.cold   "$runs" "rm -rf $cc" "$nimony" $backend $extra --silentMake --nimcache:"$cc" "$ctfe"
measure ctfe.warm   "$runs" ":" "$nimony" $backend $extra --silentMake --nimcache:"$cc" "$ctfe"
measure ctfe.edit   "$runs" "printf 'echo \"edit\"\n' >> $ctfe" "$nimony" $backend $extra --silentMake --nimcache:"$cc" "$ctfe"
measure ctfe.forced "$runs" ":" "$nimony" $backend $extra -f --silentMake --nimcache:"$cc" "$ctfe"

# ---- CTFE: bench/ctfe_bench.nim (14 consts) --------------------------------
if [ -f "$here/bench/ctfe_bench.nim" ]; then
  cb="$work/ctfe_bench.nim"
  cp "$here/bench/ctfe_bench.nim" "$cb"
  bc="$work/nc_bench"
  measure bench.cold "$runs" "rm -rf $bc" "$nimony" $backend $extra --silentMake --nimcache:"$bc" "$cb"
  measure bench.edit "$runs" "printf 'echo \"edit\"\n' >> $cb" "$nimony" $backend $extra --silentMake --nimcache:"$bc" "$cb"
fi

# ---- stdlib-wide: tall.nim -------------------------------------------------
tall="$here/tests/nimony/stdlib/tall.nim"
sc="$work/nc_stdlib"
measure stdlib.cold   "$runs" "rm -rf $sc" "$nimony" c $extra --silentMake --nimcache:"$sc" "$tall"
measure stdlib.forced "$runs" ":" "$nimony" c $extra -f --silentMake --nimcache:"$sc" "$tall"
# strutils edit: append a harmless proc to the TOOLCHAIN's copy (that is the one
# nimony compiles), rebuild, and restore the file byte for byte afterwards.
su="$root/lib/std/strutils.nim"
cp "$su" "$work/strutils.orig"
measure stdlib.edit "$runs" "printf '\nproc devloopBenchMarker*(): int = 1\n' >> $su" "$nimony" c $extra --silentMake --nimcache:"$sc" "$tall"
cp "$work/strutils.orig" "$su"
# the trailing runs left tall's cache built against the edited strutils; leave it.

# ---- the compiler compiling itself ------------------------------------------
# The headline of JIT.md 12: the largest real program in the repository (127
# modules), the way `hastur boot` builds it (debug here, because that is the
# dev loop). Both toolchains compile the SAME sources -- the fork point's, copied
# into the scratch dir -- so a source change on the branch cannot masquerade as
# a compiler change. `self.edit` appends a proc to `sem.nim`, a mid-dependency
# module, and rebuilds: what an edit to the compiler costs before it can be run.
selfsrc=${SELF_SRC:-/tmp/devloop_base/src}
if [ -d "$selfsrc" ]; then
  selfdir="$work/self"; mkdir -p "$selfdir"; cp -R "$selfsrc" "$selfdir/src"
  selfc="$work/nc_self"; selfbin="$work/self_nimony"
  selfcmd="$nimony $backend $extra --silentMake --nimcache:$selfc --out:$selfbin src/nimony/nimony.nim"
  measure self.cold     "$runs" "rm -rf $selfc" sh -c "cd $selfdir && $selfcmd"
  measure self.nochange "$runs" ":"              sh -c "cd $selfdir && $selfcmd"
  measure self.editbody "$runs" "printf '\nproc devloopBenchBody(): int = 1\n' >> $selfdir/src/nimony/sem.nim" sh -c "cd $selfdir && $selfcmd"
  if [ "$hasRun" = "1" ]; then
    # The pair the phase is judged on: the SAME body edit, then the compiler
    # asked to print its version -- once through the linked image and once out
    # of the compiler's own memory. `nimony r` writes no executable, so it gets
    # no `--out`; the nimcache is shared on purpose, because the `.asm.nif`
    # files both paths consume are the same files.
    selfnrun="$nimony n $extra -r --silentMake --nimcache:$selfc --out:$selfbin src/nimony/nimony.nim --version"
    selfrun="$nimony r $extra --silentMake --nimcache:$selfc src/nimony/nimony.nim --version"
    measure self.nrun "$runs" "printf '\nproc devloopBenchBody(): int = 1\n' >> $selfdir/src/nimony/sem.nim" sh -c "cd $selfdir && $selfnrun"
    measure self.run  "$runs" "printf '\nproc devloopBenchBody(): int = 1\n' >> $selfdir/src/nimony/sem.nim" sh -c "cd $selfdir && $selfrun"
  fi
  measure self.edit     "$runs" "printf '\nproc devloopBenchMarker*(): int = 1\n' >> $selfdir/src/nimony/sem.nim" sh -c "cd $selfdir && $selfcmd"
  measure self.forced   "$runs" ":"              sh -c "cd $selfdir && $selfcmd -f"
else
  echo "self.*: skipped, no fork-point sources at $selfsrc (SELF_SRC=<dir> to point elsewhere)"
fi

echo
echo "label: $label   toolchain: $root   runs: $runs (median)   backend=$backend (stdlib.* on c)   NIMONY_VFS=$NIMONY_VFS   EXTRA=$extra"
