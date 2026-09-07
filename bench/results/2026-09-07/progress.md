# fast-devloop progress benchmark, 2026-09-07 (continues 2026-09-06/progress.md)

```
base:     f69b8afc (master fork point), /tmp/devloop_base, arkham/nifasm from the current checkout
os:       macOS 26.6.2 arm64, Apple M5 (10 cores), Nim 2.2.10
backend:  native (`nimony n` / `nimony r`) unless stated
method:   bench/devloop_ab.sh, A/B interleaved, median of 5, load noted
```

## Run 9: B3c (nifasm resolves foreign procs from their signature) wired in

head = fast-devloop with pin c3f27fc. Load 9.8 decaying from the test runs.

| sem.nim body edit, rebuild | fork point | head | ratio |
|---|---|---|---|
| wall | 2.784 | 1.262 | 2.21x |
| cpu | 3.950 | 1.302 | 3.03x |

nativenif's own numbers for the 130-module compiler link (cpu, interleaved):
warm nothing edited 0.274 -> 0.085 s; warm one small module edited 0.274 ->
0.086 s; warm `sem.nim` edited (540 stale fragments) 0.433 -> 0.284 s, of
which 0.162 s is generating the 540 genuinely stale fragments. Byte-identical
in nine cache states; refactor gate byte-identical (verified again by the
integrator). Native bootstrap 59.8 s, stages 1 == 2 == 3.

## B3b: measured, not built

`notes/b3b.md`, `bench/results/2026-09-06/b3b.txt`. Per stage of the same
edit on head: nimsem 0.325, hexer 0.251, arkham 0.250 (3 modules), dceEmit
0.042, link 0.443 (before B3c), wall 1.377. A declaration-level incremental
hexer cannot reach its ≤ 0.2 s gate because sem's output is not
declaration-stable: appending one proc to `sem.nim` changes 465 of its 1227
top-level declarations (`sembasics.makeLocalSym` numbers locals from a
module-wide per-name counter; line info shifts on top), and arkham's labels,
rodata indices and temp names are module-scoped, so 135 of 974 declarations
emit different asm from byte-identical Leng. A `decl-stability` incremental
scenario now pins those ratios so a fix shows up as a number.

Prerequisites, in order (all in the frontend, i.e. the owner's decision):
(1) proc-derived local numbering in nimsem; (2) line-info-blind digests with
an info rebase in hexer; (3) per-declaration fragments for hexer's
module-wide tables and an intra-module inline dependency map; (4) proc-scoped
labels/rodata in arkham. Projected floor for hexer + arkham after all four:
~0.24 s (36 ms of hexer is whole-module by construction; I/O 38 ms).

## Run 10: memory -- peak resident size of the largest process, base vs head

Both benchmark scripts now report `rss`: `ru_maxrss` of the waited-for
process tree = the peak resident size of the LARGEST process in it (MB). An
in-process pipeline concentrates work into one process that used to be
spread over many, so this is the number the design's "low memory
consumption" goal is judged by. Interleaved, 3 rounds, native backend.

| scenario | base wall / cpu / peak MB | head wall / cpu / peak MB |
|---|---|---|
| sem.nim body edit, rebuild | 2.786 / 3.960 / 116 | 1.200 / 1.242 / 112 |
| compiler, cold | 5.363 / 13.882 / 116 | 5.281 / 12.422 / **216** |
| 5-const module, forced | 3.935 / 5.745 / 59 | 0.891 / 1.089 / 61 |
| hello, forced | 0.377 / 0.528 / 18 | 0.354 / 0.492 / 26 |

Where the cold build's extra 100 MB comes from (head, one process each):
`NIMONY_SPAWN=auto` (the in-process scheduler) 215 MB; `NIMONY_SPAWN=always`
147 MB; with the blob cache off still 215 MB. So ~68 MB is the driver
running nimsem/hexer nodes in its own address space (the reset drops the
pools, but the allocator's high-water mark stays and the driver's own
dependency state is live at the same time), and ~30 MB is what the head's
`nimony`/tools cost on top of the fork point's even when everything spawns
(per-tool numbers below). The edit loop and CTFE are unchanged in memory:
the engine's 256 MB arena is reserved address space, not resident pages.

Per-tool attribution of the spawn-always +30 MB was attempted by wrapping
every tool in `/usr/bin/time -l`; the wrapped builds failed early on both
sides, so that number is unattributed for now. M1 (JIT_IMPL.md) makes the
tools record their own peak RSS in their ledger fragment, which answers it
from inside the build instead.
