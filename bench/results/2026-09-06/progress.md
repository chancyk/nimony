# fast-devloop progress benchmark

Script: `bench/devloop_bench.sh <toolchain-root> <label> <runs>`. Both
toolchains compile the same inputs from the current checkout; `base` is the
fork point built in its own worktree.

```
base:     f69b8afc (master fork point), worktree /tmp/devloop_base, `hastur build all`
head:     80a2c58b fast-devloop (P0a, P0b, A1a, A1b, A1c, A2a-lengc, A2a-hexer merged)
os:       macOS 26.6.2  arm64      cpu: Apple M5 (10 cores)
nim:      Nim Compiler Version 2.2.10 [MacOSX: arm64]
cc:       Apple clang 21
mode:     NIMONY_VFS=disk (the default), C backend, debug
runs:     3 per scenario, median of wall and of cpu-sum (user+sys of the whole process tree)
caveat:   NOT QUIET. Three agents (A1d, A2a-front, B2) were building toolchains
          and running test suites throughout. Wall times are unreliable; cpu-sum
          is the number to read, and even it can inflate under memory-bandwidth
          contention. A quiet re-run is scheduled for the window after these
          agents finish and before the next wave launches (JIT_IMPL.md
          "Measuring").
```

## Run 1 (loaded machine), median of 3

| scenario | base wall | head wall | base cpu | head cpu | cpu ratio |
|---|---|---|---|---|---|
| hello.forced | 1.099 | 0.748 | 1.282 | 1.034 | 1.24x better |
| hello.nochange | 0.047 | 0.016 | 0.029 | 0.013 | 2.2x better |
| hello.edit | 0.209 | 0.128 | 0.181 | 0.137 | 1.32x better |
| ctfe.cold (tmyops, 5 consts) | 3.464 | 3.959 | 5.180 | 4.315 | 1.20x better |
| ctfe.warm | 0.013 | 0.020 | 0.011 | 0.017 | noise (10 ms) |
| ctfe.edit | 0.204 | 0.133 | 0.202 | 0.140 | 1.44x better |
| ctfe.forced | 4.189 | 2.014 | 6.382 | 3.040 | 2.10x better |
| bench.cold (ctfe_bench, 14 consts) | 6.811 | 7.870 | 10.480 | 6.349 | 1.65x better |
| bench.edit | 0.611 | 0.373 | 0.561 | 0.258 | 2.17x better |
| stdlib.cold (tall.nim) | 8.068 | 11.795 | 36.961 | 42.817 | **1.16x worse** |
| stdlib.forced | 2.899 | 4.786 | 11.559 | 13.325 | **1.15x worse** |
| stdlib.edit (strutils) | 0.733 | 0.791 | 1.718 | 1.152 | 1.49x better |

raw (wall / cpu):
```
base stdlib.cold    wall 8.068 7.721 8.202   cpu 37.675 36.961 36.915
head stdlib.cold    wall 12.659 11.795 11.279 cpu 41.286 42.817 42.837
base stdlib.forced  wall 2.899 2.852 3.466   cpu 11.559 11.415 11.947
head stdlib.forced  wall 5.656 4.128 4.786   cpu 13.325 12.928 13.692
```

## Where the stdlib cpu goes (`nimony c -f --profile tall.nim`, one run each, loaded)

| phase | base | head | delta per invocation |
|---|---|---|---|
| nifler (131) | 1.859 | 2.290 | +3.3 ms |
| nimsem (101) | 2.440 | 3.295 | +8.5 ms |
| hexer (99) | 2.228 | 3.066 | +8.5 ms |
| dceEmit (99) | 1.324 | 1.639 | +3.2 ms |
| lengc (99) | 1.133 | 1.155 | 0 |
| cc (99) | 9.096 | 8.838 | 0 |

Isolated, interleaved micro-timing of one invocation (20 runs, median cpu),
base vs head: nifler 2.3 / 2.6 ms then 2.3 / 1.9 ms; nimsem 14.3 / 14.9 ms.
No per-process regression is visible in isolation, so the in-build delta is
either load ordering (base ran first) or something that only appears with
`nifmake -j` fan-out (a shared-directory effect of the `.ledger/` fragment
writes is the candidate to test first: run with the fragment write disabled).
**Open until the quiet run.**

## Conclusions that survive the noise

- The CTFE dev loop is what the phases so far targeted, and it moved: forced
  rebuilds with consts cost half the CPU (P0a's `-f` fix + memo), the
  14-const benchmark costs 40 % less CPU cold (P0b's object cache), and every
  edit-rebuild scenario is 1.3–2.2x cheaper.
- Nothing yet targets the stdlib-wide cold build (that is A2b's fan-out
  scheduler and B3's code cache), so it must not get worse in the meantime.
  The +15 % cpu reading is the one number to re-take on a quiet machine
  before A2b is merged on top.
