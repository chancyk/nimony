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

## Run 11: F1 (declaration-stable frontend output) merged -- interleaved, load decaying from 19

head = fast-devloop with jit/f1 (locals spelled `` x.3`routine`0 ``; hexer's `.decls.nif` digests).

| scenario | fork point wall / cpu / peak MB | head wall / cpu / peak MB | wall | cpu |
|---|---|---|---|---|
| sem.nim body edit, rebuild | 2.713 / 3.987 / 116 | 0.766 / 0.748 / 102 | 3.54x | 5.33x |
| compiler, cold | 5.709 / 14.853 / 116 | 5.683 / 13.634 / 217 | 1.00x | 1.09x |

Why: the appended proc now changes 1 of 1222 `.s.nif` declarations and 0
`.x.nif` declarations (was 465 / 464), so P0c's per-module live files,
the `.c.nif` cache and nifasm's per-symbol blob cache all hit. Cost:
frontend artifacts +31 % in bytes (the owner's name in every local), cold
build +3 % cpu of which 2.6 % is the new `.decls.nif` sidecar that nothing
reads yet (B3b will). Golden churn: 21 files, every changed line a local
rename or an index offset. Follow-ups found in review: diagnostics now
print the namespaced spelling (`'s.0`testMutateWhileIterating`0' is
borrowed`) where the user wants `s`; `derefs.nim`'s `err.N` and
`controlflow.nim`'s `cf.N` still count module-wide.

## Run 12: M1 (memory budget in the scheduler) merged -- interleaved, load decaying from 18

| scenario | fork point wall / cpu / peak MB | head wall / cpu / peak MB |
|---|---|---|
| compiler, cold | 5.613 / 14.609 / 116 | 5.370 / 13.844 / **147** |
| sem.nim body edit, rebuild | 2.314 / 3.589 / 116 | 0.706 / 0.702 / 101 |

The cold peak is back to what the build costs with everything spawned; the
147 vs 116 is `dceLive` (84 -> 147 MB, P0c's 127 per-module resolve
subsets held at once; the fork point's largest process was the linker at
122 MB). `--stats` now prints a `peak MB` column per phase and a `driver
peak / largest child` line; budget rule
`clamp(physicalMemory / (32 * cores), 128 MB, 1 GB)`, `--inproc-mem-budget`.

## Run 13: the headline edit corrected -- a LIVE edit (B3b's finding)

`self.editbody` appended a private, never-called proc; DCE deleted it, so
arkham and the link cost 0 s on it and the loop read 0.71 s. The scenario is
now a statement inserted into the body of `semStmt` (called by everything),
and the old form is kept as `self.editdead`. Interleaved, 5 rounds, load 3.8:

| sem.nim LIVE edit, rebuild | fork point | head | ratio |
|---|---|---|---|
| wall | 2.913 | 1.349 | 2.16x |
| cpu | 4.148 | 1.393 | 2.98x |
| peak rss | 117 MB | 113 MB | |

Where head's 1.35 s goes (b3b.txt "grow" edit, `--profile`): nimsem 0.44,
dceLive 0.39, hexer 0.28, arkham 0.27, link 0.33 (these overlap; wall 1.35).
Two of them are new targets: `dceLive` re-runs because one module's
`.dce.nif` changed (0.39 s of whole-program live-set work for a one-body
edit), and hexer/arkham/link are whole-module because hexer's temp counters
are module-wide (F2, running). The pre-correction numbers (0.71 s) remain
valid for the dead-proc edit and are recorded above as such.

## Run 14: where nimsem and hexer spend their time on sem.nim (sampling profile)

`sample` (macOS) on the tool process, 5-6 runs, top-of-stack frames; the
question was whether a hot data structure could be kept in L2.

```
nimsem, 437 samples          hexer, 316 samples
 18.5%  _platform_memmove     27.8%  _tlv_get_addr
 15.3%  _tlv_get_addr         21.5%  _platform_memmove
 14.6%  nifcore.skip          14.6%  (outlined)
 10.5%  (outlined)            11.7%  nifcore.skip
 10.1%  rawAlloc               5.7%  nifcore.rawLineInfo
  5.3%  decRcAndFree           4.4%  rawAlloc
  4.1%  hashFarm               2.2%  subtreeWidth, addTree, symId, closeTag ...
  3.0%  programs.hasKey
  3.0%  rawDealloc
```

Reading: neither tool is bound by a table lookup (hashing + `hasKey` are
~7 % of nimsem, less of hexer). The time is copying token subtrees
(`memmove`), walking them (`skip`, `rawLineInfo`, `subtreeWidth`), and the
allocator. The token buffers themselves are the working set (sem.nim's
`.s.nif` is 7.6 MB of text; hexer's eleven passes each rebuild the module's
`TokenBuf`), so the cache-relevant lever is fewer copies of the tree per
pass, not pinning a structure. `_tlv_get_addr` is macOS thread-local
access from Nim's threaded runtime; measured, it is worth less than the
sample share suggests:

| hexer on sem.nim (cpu, 7 interleaved runs) | |
|---|---|
| plain (`--threads:on`, Nim's allocator) | 0.263 s |
| `-d:useMalloc` | 0.275 s (+5 %) |
| `--threads:off` | 0.247 s (-6 %) |
| both | 0.261 s |

(A standalone nimsem variant could not be timed in this harness -- it
resolves one module path differently from the installed one; the hexer
numbers stand on their own.)

Conclusion: `--threads:off` for the tools that never thread (hexer, lengc,
nifler, the nimony driver) is a 6 % item; nimsem needs threads for the
engine's guest. The larger lever is in hexer's pipeline design (one copy of
the module tree per pass), which is compiler work, not a cache trick.

## Run 15: F2 (hexer's synthesized names per declaration) merged -- live edit, interleaved, 5 rounds, load ~12-17

| sem.nim LIVE edit, rebuild | fork point | head | ratio |
|---|---|---|---|
| wall | 2.677 | 1.255 | 2.13x |
| cpu | 3.866 | 1.292 | 2.99x |
| peak rss | 117 MB | 114 MB | |

F2 moved the live edit from 3 of 1785 changed lowering-output declarations
to what hexer can prove (890 -> 3), but nifasm still records 627 fragments
for `sem` because `blobcache.sameSource` validates per MODULE, and arkham
still lowers the whole module; the wall gain from F2 alone is small
(1.35 -> 1.26 s). The two next levers are therefore per-symbol blob
validity in nifasm (627 -> ~3 stale) and per-proc splicing in arkham; after
those, `dceLive` (0.39 s of whole-program liveness for a one-body edit)
and the per-module sem re-check (0.44 s) are what is left.

## Run 16: B3d (per-declaration blob validity in nifasm, per-proc names in arkham) merged -- interleaved, load decaying from 21

| scenario | fork point wall / cpu / peak MB | head wall / cpu / peak MB | wall | cpu |
|---|---|---|---|---|
| sem.nim LIVE edit, rebuild | 2.650 / 3.832 / 117 | 1.084 / 1.124 / 107 | 2.44x | 3.41x |
| compiler, cold | 5.447 / 14.308 / 116 | 5.405 / 13.928 / 147 | 1.01x | 1.03x |

Per stage on the live edit (b3d.txt): nimsem 0.34, dceLive 0.36 (first
rebuild after an edit only), hexer 0.27, arkham 0.26 (3 modules), dceEmit
0.05, link 0.12 (was 0.32; blob recorded 627 -> 18). Pin: nativenif
7b838ec. The arkham commit changes 137 of 2583 refactor-gate artifacts by
label/temp renames only; no image hash moved; one arm64 nativecg golden
regenerated. Left: arkham splicing (~0.26 -> ~0.1 s), an incremental live
set for dceLive (0.36 s), the per-module sem re-check (0.34 s, owner).

## Run 17: H1 merged (dceLive's fixpoint no longer deep-copies a module per pop) -- interleaved, load ~20 (B3e building)

| scenario | fork point wall / cpu / peak MB | head wall / cpu / peak MB | wall |
|---|---|---|---|
| sem.nim live edit, body only (`self.editbody`) | 2.567 / 3.869 / 117 | 1.175 / 1.217 / 107 | 2.18x |
| sem.nim live edit that adds a proc AND a call (`self.editcall`, new) | 2.286 / 3.541 / 117 | 1.140 / 1.178 / 147 | 2.01x |

`self.editcall` is the edit that changes the call graph every round, so
`dceLive` runs every round (a body-only edit leaves the `.dce.nif`
byte-identical after round 0, H1's finding); its peak is `dceLive`'s
147 MB. H1: `dceLive` 0.36 -> 0.05 s (`markLive` took the module table by
value: a whole `ModuleAnalysis` deep-copied per worklist pop, 7867 times),
131 live files byte-identical; the incremental live set was measured as
worth ~11 ms and not built. Absolutes this run carry B3e's build load; the
ratios and the per-stage numbers in h1.txt are the evidence.
