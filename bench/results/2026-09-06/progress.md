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

## Run 2 (quiet: no agents running; load avg decaying from the test runs before it), median of 3

head = 9aa41488 (adds A1d, A2a-lengc/hexer/front, B2). `head-engine` = same toolchain with `--ctfe:engine`.

| scenario | base wall | head wall | engine wall | base cpu | head cpu | engine cpu | head cpu vs base | engine cpu vs base |
|---|---|---|---|---|---|---|---|---|
| hello.forced | 0.427 | 0.429 | 0.438 | 0.666 | 0.686 | 0.690 | 0.97x | 0.97x |
| hello.nochange | 0.015 | 0.011 | 0.011 | 0.012 | 0.010 | 0.009 | 1.20x | 1.33x |
| hello.edit | 0.081 | 0.085 | 0.084 | 0.107 | 0.111 | 0.109 | 0.96x | 0.98x |
| ctfe.cold | 2.506 | 2.358 | 1.030 | 3.764 | 3.006 | 1.732 | 1.25x | 2.17x |
| ctfe.warm | 0.013 | 0.012 | 0.012 | 0.011 | 0.010 | 0.010 | 1.10x | 1.10x |
| ctfe.edit | 0.205 | 0.097 | 0.091 | 0.200 | 0.118 | 0.109 | 1.69x | 1.83x |
| ctfe.forced | 3.712 | 1.432 | 0.991 | 5.502 | 2.319 | 1.582 | 2.37x | 3.48x |
| bench.cold | 6.069 | 5.239 | 1.744 | 9.337 | 5.401 | 2.856 | 1.73x | 3.27x |
| bench.edit | 0.437 | 0.120 | 0.118 | 0.436 | 0.165 | 0.162 | 2.64x | 2.69x |
| stdlib.cold | 5.854 | 5.988 | 5.904 | 31.779 | 32.478 | 33.273 | 0.98x | 0.96x |
| stdlib.forced | 2.007 | 2.133 | 2.226 | 9.307 | 9.865 | 10.320 | 0.94x | 0.90x |
| stdlib.edit | 0.448 | 0.426 | 0.433 | 1.277 | 0.748 | 0.756 | 1.71x | 1.69x |

raw (wall / cpu):
```
base    hello.forced    wall 0.427 0.427 0.424  cpu 0.666 0.657 0.668
head    hello.forced    wall 0.429 0.428 0.437  cpu 0.686 0.681 0.696
engine  hello.forced    wall 0.438 0.440 0.427  cpu 0.682 0.695 0.690
base    hello.nochange  wall 0.015 0.015 0.015  cpu 0.012 0.012 0.012
head    hello.nochange  wall 0.011 0.011 0.011  cpu 0.010 0.010 0.009
engine  hello.nochange  wall 0.011 0.011 0.011  cpu 0.010 0.009 0.009
base    hello.edit      wall 0.081 0.083 0.081  cpu 0.107 0.107 0.106
head    hello.edit      wall 0.083 0.085 0.085  cpu 0.096 0.111 0.111
engine  hello.edit      wall 0.084 0.085 0.082  cpu 0.109 0.110 0.095
base    ctfe.cold       wall 3.272 2.503 2.506  cpu 3.784 3.729 3.764
head    ctfe.cold       wall 2.724 2.358 2.357  cpu 3.019 2.961 3.006
engine  ctfe.cold       wall 1.029 1.034 1.030  cpu 1.734 1.732 1.720
base    ctfe.warm       wall 0.013 0.013 0.013  cpu 0.011 0.011 0.011
head    ctfe.warm       wall 0.012 0.012 0.012  cpu 0.010 0.010 0.010
engine  ctfe.warm       wall 0.012 0.012 0.012  cpu 0.010 0.010 0.010
base    ctfe.edit       wall 0.207 0.205 0.205  cpu 0.198 0.200 0.200
head    ctfe.edit       wall 0.097 0.097 0.096  cpu 0.101 0.119 0.118
engine  ctfe.edit       wall 0.091 0.091 0.090  cpu 0.109 0.116 0.102
base    ctfe.forced     wall 3.712 3.661 3.730  cpu 5.520 5.410 5.502
head    ctfe.forced     wall 2.041 1.417 1.432  cpu 2.297 2.319 2.336
engine  ctfe.forced     wall 0.871 0.993 0.991  cpu 1.431 1.597 1.582
base    bench.cold      wall 6.892 6.062 6.069  cpu 9.432 9.263 9.337
head    bench.cold      wall 6.218 5.194 5.239  cpu 5.490 5.303 5.401
engine  bench.cold      wall 1.741 1.788 1.744  cpu 2.856 2.855 2.862
base    bench.edit      wall 0.460 0.436 0.437  cpu 0.483 0.418 0.436
head    bench.edit      wall 0.144 0.119 0.120  cpu 0.218 0.165 0.165
engine  bench.edit      wall 0.141 0.118 0.117  cpu 0.216 0.161 0.162
base    stdlib.cold     wall 5.823 6.017 5.854  cpu 31.586 31.779 32.245
head    stdlib.cold     wall 5.866 5.988 6.021  cpu 32.322 32.478 32.840
engine  stdlib.cold     wall 5.881 5.904 5.994  cpu 33.006 33.273 33.750
base    stdlib.forced   wall 1.980 2.074 2.007  cpu 9.157 9.567 9.307
head    stdlib.forced   wall 2.100 2.209 2.133  cpu 9.648 10.159 9.865
engine  stdlib.forced   wall 2.120 2.226 2.240  cpu 10.096 10.320 10.320
base    stdlib.edit     wall 0.456 0.446 0.448  cpu 1.306 1.277 1.269
head    stdlib.edit     wall 0.426 0.410 0.493  cpu 0.748 0.732 1.374
engine  stdlib.edit     wall 0.433 0.410 0.493  cpu 0.756 0.735 1.376
```

Reading: the stdlib-wide scenarios move 2-6 % between base and head and 5 %
between head and head-engine, which share that code path exactly, so the
run-1 '+15 %' was contention and there is no stdlib regression above the
noise floor (~5 %). Keep it in every run. The CTFE loop: a fresh nimcache with
5 consts 2.4x faster, forced 3.7x, the 14-const benchmark cold 3.5x and edit
3.6x; nothing changed for hello world, as expected before A2b.

## Run 2b: interleaved A/B on the one open question (stdlib.forced), 5 rounds

`bench/devloop_ab.sh /tmp/devloop_base . stdlib.forced 5` (A = base f69b8afc,
B = head 9aa41488; two agents building in the background, which an
interleaved run tolerates):

```
round 0  A  wall 2.749  cpu 10.017      B  wall 3.479  cpu 10.690
round 1  A  wall 3.883  cpu 10.742      B  wall 3.666  cpu 11.201
round 2  A  wall 2.929  cpu 10.437      B  wall 2.700  cpu 10.514
round 3  A  wall 2.506  cpu 10.048      B  wall 2.769  cpu 10.329
round 4  A  wall 3.552  cpu 10.855      B  wall 2.796  cpu 10.484
A cpu median 10.437 min 10.017 | B cpu median 10.514 min 10.329
B/A cpu: 1.007 (median), 1.031 (min)
```

Verdict: no stdlib-wide regression from the merged phases (≤ 3 %, inside the
round-to-round spread). The monotonic rise across run 2's three block passes
was drift between passes, which is why the 5 % question is answered with the
interleaved script and the 2x questions with the table.
