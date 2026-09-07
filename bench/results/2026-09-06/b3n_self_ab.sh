#!/bin/sh
# Interleaved A/B for the two `self.*` scenarios `bench/devloop_ab.sh` does not
# cover: `self.editbody` and `self.run`, cache ON vs cache OFF, on ONE toolchain
# (the head worktree), with the arms alternating inside one loop so that a busy
# machine perturbs both equally.
#
# Both arms share NOTHING but the toolchain: each arm gets its own copy of the
# fork-point sources and its own nimcache, so the blob cache one arm writes is
# never the blob cache the other reads. Every measured run is warm -- a priming
# build precedes the loop and the edit is appended before each timed run, which
# is exactly what `devloop_bench.sh`'s `measure` does.
#
# Usage: self_ab.sh <nimony-root> <rounds>
set -u
root=$1
rounds=${2:-5}
nimony="$root/bin/nimony"
src=/tmp/devloop_base/src
work=/tmp/b3n/self_ab
rm -rf "$work"; mkdir -p "$work"

for arm in on off; do
  mkdir -p "$work/$arm"
  cp -R "$src" "$work/$arm/src"
done
flag_on=""
flag_off="--no-blobcache"

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

cmd_editbody() { # arm flags
  echo "cd $work/$1 && $nimony n $2 --silentMake --nimcache:$work/$1/nc --out:$work/$1/bin src/nimony/nimony.nim"
}
cmd_run() { # arm flags
  echo "cd $work/$1 && $nimony r $2 --silentMake --nimcache:$work/$1/nc src/nimony/nimony.nim --version"
}

# Prime: one full build per arm, so every timed run below is an incremental one
# and the cache arm's store is populated.
for arm in on off; do
  f=$(eval echo "\$flag_$arm")
  sh -c "$(cmd_editbody "$arm" "$f")" >/dev/null 2>&1
done

for scen in editbody run; do
  wall_on=""; wall_off=""; cpu_on=""; cpu_off=""
  i=0
  while [ "$i" -lt "$rounds" ]; do
    for arm in on off; do
      f=$(eval echo "\$flag_$arm")
      printf '\nproc devloopBenchBody%s(): int = 1\n' "$i$arm" \
        >> "$work/$arm/src/nimony/sem.nim"
      if [ "$scen" = editbody ]; then c=$(cmd_editbody "$arm" "$f")
      else c=$(cmd_run "$arm" "$f"); fi
      out=$(runone sh -c "$c")
      eval "wall_$arm=\"\$wall_$arm ${out%% *}\""
      eval "cpu_$arm=\"\$cpu_$arm ${out##* }\""
    done
    i=$((i+1))
  done
  med() { python3 -c "import statistics,sys; print(f'{statistics.median([float(x) for x in sys.argv[1:]]):.3f}')" $@; }
  printf 'self.%-9s cache=on   wall %s  cpu %s   raw wall:%s  cpu:%s\n' \
    "$scen" "$(med $wall_on)" "$(med $cpu_on)" "$wall_on" "$cpu_on"
  printf 'self.%-9s cache=off  wall %s  cpu %s   raw wall:%s  cpu:%s\n' \
    "$scen" "$(med $wall_off)" "$(med $cpu_off)" "$wall_off" "$cpu_off"
done
