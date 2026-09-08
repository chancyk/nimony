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

## Run 18: B3e (arkham splices unchanged procs) merged -- interleaved, nothing else running, load decaying from 21

| scenario | fork point wall / cpu / peak MB | head wall / cpu / peak MB | wall | cpu |
|---|---|---|---|---|
| sem.nim live edit, body only | 2.304 / 3.562 / 117 | 0.917 / 0.938 / 107 | 2.51x | 3.80x |
| sem.nim live edit, new proc + call | 2.686 / 3.866 / 117 | 1.136 / 1.154 / 147 | 2.36x | 3.35x |
| compiler, cold | 5.676 / 14.666 / 116 | 5.198 / 13.919 / 147 | 1.09x | 1.05x |

B3e: `--asmcache:DIR` on the arkham node; `<mod>.arkham.nif` sidecar of
per-proc digests and byte ranges into the module's previous `.asm.nif`;
arkham 0.259 -> 0.089 s on the live edit (523/526 procs spliced); 8 cache
states x 5 targets byte-identical; refactor gate byte-identical; pin
nativenif 5f6f011. Paused here (owner's instruction). What is left in the
0.92 s: nimsem ~0.34 (the per-module re-check, owner's decision), hexer
~0.27 (whole-module lowering; B3b's incremental `expand`, floor ~0.11 s),
link 0.12, arkham 0.09, dceEmit 0.05.

## Run 19: the headline re-taken after the six-commit upstream merge chain -- interleaved, machine quiet, load 1.6-3.5 decaying

head = `95fff89d` (fast-devloop tip; measured from the worktree `/tmp/merge-u1`,
branch `merge/u6b`, same commit). Base = `/tmp/devloop_base` (`f69b8afc`).
Raw rounds: `bench/results/2026-09-07/postchain.txt`.

| scenario | fork point wall / cpu / peak MB | head wall / cpu / peak MB | wall | cpu |
|---|---|---|---|---|
| `self.editbody` (the verdict: live edit in `sem.nim`) | 2.577 / 3.772 / 117 | 1.020 / 1.045 / 107 | 2.53x | 3.61x |
| `self.editcall` (edit adds a proc AND a call) | 2.619 / 3.803 / 117 | 1.277 / 1.298 / 146 | 2.05x | 2.93x |
| `self.editdead` (private never-called proc; DCE deletes it) | 2.729 / 3.890 / 116 | 0.810 / 0.806 / 100 | 3.37x | 4.83x |
| `self.nochange` (nothing edited) | 0.096 / 0.093 / 4 | 0.045 / 0.044 / 7 | 2.13x | 2.11x |
| `self.cold` | 5.241 / 13.598 / 116 | 5.296 / 13.902 / 175 | 0.99x | 0.98x |
| `hello.forced` (attribution) | 0.335 / 0.473 / 18 | 0.353 / 0.487 / 26 | 0.95x | 0.97x |
| `ctfe.forced` (attribution) | 3.549 / 5.188 / 59 | 0.834 / 0.989 / 62 | 4.26x | 5.25x |

`self.nochange` is a new `devloop_ab` scenario (prep is a no-op) added with this
run, so that the "compiler, no change" row of `SUMMARY.md` is taken the same
interleaved way as the rest of the table instead of out of `devloop_bench.sh`.

Two things about this reference that were implicit before and are now stated.
**First**, `/tmp/devloop_base`'s `bin/arkham` and `bin/nifasm` have neither
`--blobcache` nor `--asmcache`: they predate B3/B3e and they predate BOTH of the
chain's nativenif re-pins (`3ec73fef` and `9d7fcf78`). The headline therefore
spans two upstream assembler changes as well as our own nativenif chain and the
compiler's. That is the right fixed reference for a headline -- it is what a
user at the fork point actually had -- but it is not a compiler-only number.
**Second**, the fork-point A side drifts between sessions and these absolutes
are only quotable as the pair taken in this run: `self.editbody` A reads
3.772 s cpu here against 3.562 in run 18 and 3.541 in run 17, with nothing
about A changed (BENCHMARK.md 1).

Two numbers moved against run 18 for reasons that are NOT this chain, and are
recorded rather than smoothed:

* `self.cold` head is now level with the fork point (0.98x cpu) where run 18 read
  1.05x in our favour. That is the chain: run 20 measures it directly at 1.072.
* `self.cold` head peak RSS reads **175 MB** where run 18 logged 147 MB. This is
  not the chain either -- the PRE-chain toolchain reads 176 MB in the same
  session (run 20), i.e. the chain moved it by -1 MB. Both sides are stable to
  1 MB within a session and differ from run 18's session for a reason this run
  did not establish; the ledger that feeds M1's scheduler lives under the
  nimcache and `self.cold` wipes it every round, so the usual explanation does
  not apply. Flagged as unexplained: the low-memory gate should be re-read on a
  fresh session before it is trusted either way.

## Run 20: what the six-commit merge chain cost -- pre-chain vs post-chain, interleaved, load 1.3-3.7

**The question run 19 cannot answer.** `devloop_ab` interleaves within a run, so
a chain cost is one invocation with the pre-chain toolchain as A and the
post-chain toolchain as B -- never two fork-point ratios divided (BENCHMARK.md 1;
that trap was hit earlier in this session and cost the A side 3.536 -> 3.879).

A = `/tmp/prechain` (`6870790c`, fast-devloop's tip before the chain, built this
session against nativenif `5f6f011e`), B = `/tmp/merge-u1` (`95fff89d`).

| scenario | pre-chain wall / cpu / peak MB | post-chain wall / cpu / peak MB | cpu ratio |
|---|---|---|---|
| `self.editbody` | 0.907 / 0.921 / 107 | 1.034 / 1.048 / 107 | **1.138** |
| `self.editcall` | 1.119 / 1.132 / 147 | 1.275 / 1.298 / 146 | **1.147** |
| `self.editdead` | 0.703 / 0.700 / 101 | 0.812 / 0.809 / 100 | **1.156** |
| `self.nochange` | 0.045 / 0.044 / 7 | 0.045 / 0.044 / 7 | 1.000 |
| `self.cold` | 4.809 / 12.850 / 176 | 5.257 / 13.775 / 175 | 1.072 |
| `hello.forced` | 0.315 / 0.442 / 28 | 0.349 / 0.479 / 25 | 1.084 |
| `ctfe.forced` | 0.767 / 0.932 / 64 | 0.830 / 0.993 / 61 | 1.065 |

**Every compiling scenario is over the 5 % rule; peak RSS is untouched (1.00,
0.99).** `self.nochange` is 1.000 to three digits, which is the shape of the
thing: the no-op path does no compilation and costs exactly what it did, so the
regression is in work done per module, not in startup, tool discovery or the
build graph.

### Where it comes from: five interleaved runs, one per segment of the chain

Each row is its own `devloop_ab` invocation on `self.editbody`, A and B adjacent
commits, so each ratio is read only against the A it was measured beside.

| segment | A -> B | what it is | cpu ratio |
|---|---|---|---|
| upstream steps 1-3 | `6870790c` -> `f61c0e58` | `import` shadowing, `ref` sum-type ctor, and the nativenif re-pin to `3ec73fef` | 0.998 |
| upstream step 4 | `f61c0e58` -> `450a0831` | **`c6be04e1` "no globals in nifcore"** | **1.057** |
| upstream step 5 | `450a0831` -> `0ece350b` | `38f67463` std/http tag space | 1.005 |
| **ours** | `0ece350b` -> `643569c2` | the F1 respelling | **1.006** |
| upstream step 6 | `643569c2` -> `95fff89d` | **`e1da48e9` nifsyms refactor + pin `9d7fcf78`** | **1.066** |
| | product | | **1.137** |
| | direct | `6870790c` -> `95fff89d` | **1.138** |

The product of the five segments and the single end-to-end measurement agree to
one part in a thousand, which is the check that no segment was double-counted or
missed.

**Two upstream commits are the whole of it, and they are the same kind of
commit.** `c6be04e1` takes nifcore's globals out (+5.7 %) and `e1da48e9`
decomposes a symbol into a record whose compatibility view BUILDS a spelling
where `pool.syms[id]` used to lend one (+6.6 %). Both put an indirection on the
hottest read in the pipeline. **Nothing of ours is in the number**: our only
non-upstream commit in the chain, the F1 respelling, is 1.006 -- confirming,
against a proper interleaved A side this time, the 0.990 its own author
measured (`notes/f1-respell.md` 5).

Two supporting runs, coarser and consistent:

| A -> B | what it varies | cpu ratio |
|---|---|---|
| `/tmp/prechain` -> `/tmp/f1-respell` | steps 1-5 + the respell together | 1.070 |
| `/tmp/f1-respell` -> `/tmp/merge-u1` | step 6 together | 1.066 |
| `/tmp/hyb15` -> `/tmp/f1-respell` | ONLY the assembler (arkham+nifasm `5f6f011e` vs `3ec73fef`), same nimony both sides | 1.012 |
| `/tmp/prechain` -> `/tmp/hyb15` | steps 1-5 + respell with the OLD assembler on both sides | 1.081 |

`1.070 x 1.066 = 1.140`, and the step-6 figure reproduces the step-6 agent's
own `1.074` independently. The assembler-swap pair says the step-3 re-pin
carries ~1 % of it and the compiler side carries the rest, which the
commit-by-commit split then confirms exactly (steps 1-3 as a block: 0.998).

A note on method, because it cost a wrong number before it was caught: the
first attempt at the assembler swap built the hybrid as a directory of symlinks
to the donor worktree with a real `bin/`. The self-compile fails on it
(`cannot open <nimcache>/syn*.s.nif` -- a CTFE sub-compile), and it fails
IDENTICALLY with the donor's own unmodified assembler, so the failure is the
symlinked root, not the swap. `/tmp/hyb15` is an APFS clone (`cp -Rc`) of the
donor with two binaries replaced, and self-compiles.

### The splice reference, settled

`ARKHAM_CACHE_STATS=1`, cold build then the `self.editbody` edit applied three
times. Steady from the first edit in every combination -- the cache is written
by the cold run of the same toolchain, so no rename intervenes and the
"`spliced 0 lowered N` on the first build after a rename" caution does not bite.

| corpus | toolchain | main module | largest neighbour | `sem.nim` |
|---|---|---|---|---|
| fork point (`f69b8afc:src`) | pre-chain `6870790c` | 8 / 1 | 76 / 2 | 523 / 3 |
| fork point (`f69b8afc:src`) | post-chain `95fff89d` | 8 / 1 | 76 / 2 | 523 / 3 |
| branch (`643569c2:src`) | pre-chain `6870790c` | 11 / 1 | 82 / 2 | 525 / 3 |
| branch (`643569c2:src`) | post-chain `95fff89d` | 11 / 1 | 82 / 2 | 525 / 3 |
| branch (`95fff89d:src`) | post-chain `95fff89d` | 11 / 1 | 82 / 2 | 525 / 3 |

(spliced / lowered; `stale` equals `lowered` in every line above.)

**The reference is a pair of numbers, one per corpus, and the toolchain is not a
variable in it.** On the fork-point corpus -- the one `devloop_bench.sh` and
`devloop_ab.sh` use by default, and the one `notes/b3e.md` recorded -- it is
**8/1, 76/2, 523/3**, reproducing `b3e.md` line for line. On the branch's own
corpus it is **11/1, 82/2, 525/3**; the totals are larger (12, 84, 528 against
9, 78, 526) only because the compiler's own sources have grown, and the number
B3e is about, how many procs an edit costs, is **1, 2 and 3 either way**. The
two branch corpora `643569c2:src` and `95fff89d:src` give the same counts, so
the merge chain moved splice behaviour by exactly zero, confirmed here by
running the pre-chain and post-chain toolchains over the same corpus.

`notes/f1-respell.md` 5's **11/1, 83/1, 527/1** does not reproduce. Its totals
(12, 84, 528) are right for the branch corpus, so it is the split that is
wrong: it claims 1 proc re-lowered in all three modules where three toolchains
over two corpora give 1, 2 and 3. Treat the two rows above as the reference and
`11/1, 83/1, 527/1` as superseded.

---

## Run 21: B4 stage 1 against its parent -- interleaved, machine quiet

A = `/tmp/merge-u1` (`95fff89d`, which is `5df66183`'s code: the tip commit
touches no `src/`), B = `/tmp/b4/nimony` (`jit/b4`, stage 1). Raw rounds:
`bench/results/2026-09-07/b4stage1.txt`.

| scenario | A wall / cpu / peak MB | B wall / cpu / peak MB | B/A cpu | B/A rss |
|---|---|---|---|---|
| `self.editbody` | 1.018 / 1.044 / 107 | 1.024 / 1.047 / 107 | **1.003** | 1.00 |

Neutral, as it should be: stage 1 adds two modules and a flag arm that no
compile-graph node reaches. The A side also reproduces run 19's head column
(1.020 / 1.045 / 107) to three digits, which is the check that the two runs are
commensurable.

### A trap this run walked into first, worth writing down

The obvious base -- `/Users/chanc/Projects/nimony`, the main checkout, which
IS at the tip commit -- gave **1.127 cpu**, an apparent 13 % regression. It is
not one. That tree's `bin/nimony` was last built at 15:50, i.e. **before**
`6870790c`, so its toolchain is the PRE-CHAIN one and the ratio measured is the
merge chain (run 20: 1.138), not the change. Run 19 measured the head from
`/tmp/merge-u1` for the same reason and did not say so.

**The rule: a base is a BUILT TOOLCHAIN, not a commit.** Check the mtime of
`bin/nimony` against the commit date before believing a ratio, or rebuild the
base. The main checkout is not a safe default base while it holds an older
build than its own HEAD.

---

## Run 22: B4 stage 2 against its parent -- interleaved

A = `/tmp/merge-u1` (`95fff89d`, the code `jit/b4` branched from), B =
`/tmp/b4/nimony` (`jit/b4`, the whole phase). Raw rounds:
`bench/results/2026-09-07/b4stage2.txt`.

| scenario | A wall / cpu / peak MB | B wall / cpu / peak MB | B/A cpu | B/A rss |
|---|---|---|---|---|
| `self.editbody` | 1.043 / 1.068 / 107 | 1.055 / 1.074 / 107 | **1.006** | 1.00 |

Neutral, and it has to be: B4 adds five modules, a stdlib module, two nifasm
fields and a command, and no compile-graph node reaches any of them.
`nimony r --guest:subprocess` is opt-in and `nimony dev` is a different command,
so the measured path is the one that was measured before.

For the record, the numbers the PHASE is about, which `devloop_ab` has no
scenario for:

| | in-process | through `nimrun` |
|---|---|---|
| 50 runs from one host process | 51 threads, +13.56 GB mapped, 0.52 s | 1 thread, no growth, 0.15 s |
| a body-edit reload of the demo, edit to new code running | -- | one rebuild (~1 s) plus a 0.09 s re-assemble and one 12-byte store |
