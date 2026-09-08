# fast-devloop, for review

Branch `fast-devloop` off `master` f69b8afc. Goal: the edit-build-run loop of
the compiler itself, on the native backend, without changing what the
compiler produces. This file is the decision aid; `JIT.md` is the design,
`JIT_IMPL.md` the phase log, `notes/<phase>.md` the details,
`bench/results/*/progress.md` every number with its raw runs, `BENCHMARK.md`
how to take them again.

## Numbers (native backend, interleaved A/B, fork point vs branch)

Re-taken 2026-09-07 after the six-commit upstream merge chain, branch tip
`95fff89d` against fork point `f69b8afc`, one interleaved run per row
(`bench/results/2026-09-07/progress.md` run 19, raw in `postchain.txt`).

| scenario | before | after | peak RSS before / after |
|---|---|---|---|
| compiler compiling itself, a statement added to a called proc in `sem.nim` | 2.58 s | 1.02 s | 117 / 107 MB |
| same, the edit also adds a proc and a call to it (call graph changes) | 2.62 s | 1.28 s | 117 / 146 MB |
| same file, a private never-called proc appended (DCE deletes it) | 2.73 s | 0.81 s | 116 / 100 MB |
| after the edit, run the compiler from memory (`nimony r`) | no such command | build + ~20 ms | |
| hello world, edit, build and run | 0.32 s | 0.033 s | 18 / 26 MB |
| one compile-time evaluation (`const` needing a sub-compile) | 450–490 ms, 32 processes | ~27 ms, 0 processes | 59 / 61 MB |
| compiler, no change | 96 ms | 45 ms | 4 / 7 MB |
| compiler, cold | 5.24 s | 5.30 s | 116 / 175 MB |

Read as a pair per row and not against another session's: the fork-point A side
drifts (this run's `self.editbody` A is 3.772 s cpu against 3.562 in run 18,
with nothing about A changed), which is why `BENCHMARK.md` §1 forbids
comparing ratios across invocations. `/tmp/devloop_base`'s `arkham`/`nifasm`
have neither `--blobcache` nor `--asmcache`, so they predate B3/B3e **and both
of the chain's nativenif re-pins** (`3ec73fef`, `9d7fcf78`): this table spans two
upstream assembler changes as well as ours and the compiler's. It is the right
fixed reference for a headline — it is what a user at the fork point had —
but it is not a compiler-only number.

Two rows carry the six upstream commits merged on 2026-09-07, which cost the
edit loop 13.8 % of cpu on their own (run 20, measured pre-chain against
post-chain directly): **cold is now level with the fork point** where it was
5 % ahead, and the live edit is 1.02 s where it was 0.92 s. The two rows not
re-taken this round (`nimony r`, hello edit-and-run, one CTFE evaluation) come
from `devloop_bench.sh` and are 10x-class numbers that the chain's ~14 % cannot
have changed in kind. The cold peak RSS of 175 MB is 147 MB in run 18's session
for the same code and reads 176 MB for the PRE-chain toolchain in this one —
i.e. not the chain, and not yet explained; see run 19.

Correctness evidence, all automated and green: `hastur boot --boot-backend:native`
stages 1 = 2 = 3 byte-identical; `hastur tests/nimony` 795/795 in every mode;
`tests/ctfe_diff` byte-compares every compile-time result and the calling
module's `.s.nif` across every mode pair (0 differences); nativenif's
`tools/refactor_gate.sh` byte-identical (2583 artifacts).

## What changed, one decision per row

Every row keeps the artifacts on disk as they are, adds no optimizer, tier or
speculation (JIT.md 2), and has an escape hatch to today's behaviour.

| # | change | touches | why it is sound | verify with |
|---|---|---|---|---|
| 1 | **Bugs fixed** (P0a/P0c/H1): `-f` was forwarded into every CTFE sub-compile; `runEval` never consulted its own memo; `.live.nif` was hash-ordered so `OnlyIfChanged` never held and every edit re-emitted all modules' `.c.nif`; `dceLive`'s fixpoint deep-copied a whole module analysis per worklist pop (0.36 → 0.05 s, 19 lines) | `nimony.nim`, `semos.nim`, `dce2.nim`, `dce1.nim` | same outputs, fewer re-runs; 127 `.c.nif` byte-identical before/after | `hastur test tests/incremental` |
| 2 | **Ownership rule**: the main module never owns a generic instantiation another module also offers | `dce2.resolveSymbolConflicts` | a shared module's `.c.nif` no longer depends on which main it links with; what makes caches hit | `hastur boot` byte-identical |
| 3 | **Caches**: content-addressed `.o` (`ocache/`), `.c.nif` for CTFE's stdlib closure (`ccache/`), arkham's `asmcache/`, nifasm's per-symbol `blobcache/` | `deps.nim`, `engine.nim`, nativenif `blobcache.nim` | keyed on content + tool stamp; a wrong hit is a loud unresolved symbol, not wrong code; `NIMONY_CCACHE=off`, `--no-blobcache` | `tests/ctfe_engine`, nativenif `tests/tester.nim` |
| 4 | **CTFE on the engine** (B2/A2c): after `.c.nif`, arkham + nifasm in-process into an arena, `main` called; the sub-compile's frontend runs in the parent with its pools snapshotted | `engine.nim`, `semos.nim`, `exprexec.nim`; nimsem links arkham/nifasm (+2.7 MB) | runs arkham's AOT bytes ("CT eval is real compilation"); any `AsmError` falls back to the subprocess; `--ctfe:subprocess`, `NIMONY_CTFE_ENGINE=off`; default `auto` = engine on macOS/arm64 only | `tests/ctfe_diff` (0 differences) |
| 5 | **nativenif as a library** (B1): `generateAsmBuf`, `AsmSession`, `AsmError` instead of `quit`, shared `hostfixup.nim`, `image/memory.nim`, `hostsyms.nim`, `hostrun.nim` | `../nativenif` (pin in `src/nativenif.commit`) | CLI output byte-identical (refactor gate); memory image code hash-equal to the file writer's for 234 fixtures | `tools/refactor_gate.sh` |
| 6 | **Incremental assembly** (B3/B3c/B3d/B3e): nifasm caches emitted fragments per symbol, validated per declaration (asm-NIF has no line info, so a declaration's bytes are its identity); foreign procs resolved from their signature; arkham names labels and temps per proc so unchanged procs assemble byte-identically | nativenif `blobcache.nim`, `core/declhead.nim`, `core/asmdecls.nim`, arkham `CodeGen.enterProc`, `asmcache`; `deps.arkhamCacheDir` | the DCE worklist is untouched (same pops, same order); sections byte-identical in nine cache states; 127-module warm link 0.84 s → 0.086 s, a one-proc edit re-records 18 fragments instead of 627, and arkham on the edited module 0.26 → 0.09 s with byte-identical output in 8 cache states × 5 targets | nativenif `blobcache_selftest` |
| 6b | **Incremental lowering** (B3e): arkham keeps a `<mod>.arkham.nif` sidecar of each proc's line-info-blind `.c.nif` digest and the byte range its text occupies in the `.asm.nif` beside it, and copies the text of every unchanged proc instead of lowering it. No generated byte is cached — the bytes come from the module's own previous output, whose content hash the sidecar records, so the two cannot disagree | nativenif `arkham/core/{asmcache,asmwrite,cnifdigest,cachedrv}.nim`, `deps.arkhamCacheDir` | a live edit splices 523 of `sem.nim`'s 526 procs and 76 of its largest neighbour's 78; arkham 0.26 → 0.089 s, cold −2 %; `NIMONY_ARKHAMCACHE=off`, `ARKHAM_CACHE_STATS=1` | nativenif `arkhamsplice_selftest` |
| 7 | **`nimony r`** (B1): the native graph minus the link node, assembled in-process, `main` called from the arena | `nimony.nim`, `deps.nim`, `engine.nim` | same graph as `nimony n`; one proc is the run boundary for a later out-of-process guest; `--out` still writes the executable | `tests/nimony_r` |
| 8 | **Tools as procs, nifmake as a library, a scheduler** (A2a/A2b): `runNifler/Nimsem/Hexer/Lengc` + `reset*Globals`; `nifmake/dag.nim`; `nimony` runs a DAG depth in-process when the ledger says its serial cost ≤ a fan-out's | `nimsem/hexer/lengc` entry files, `programs.nim`, `nifpools.nim`, `nifmake/`, `phases.nim`; `nimony` links nimsem+hexer+lengc (2.9 → 4.8 MB) | two runs in one process produce the bytes of two processes (`tests/inproc`); `--spawn:always` / `--vfs:disk` = today's process tree exactly; nifler stays a process | `hastur tests/inproc`, `--report` identical across modes |
| 9 | **Cost ledger + artifact store** (A1, M1): every tool writes `.ledger/` timing and peak-RSS fragments, nifmake folds spawn costs, `--stats` prints them; the scheduler uses both time and memory estimates; `--vfs:memory\|memory+spill\|disk\|verify` adapter behind `vfs.nim`'s relays | `src/lib/ledger.nim`, `artifactstore.nim`, ~36 call sites moved onto the relays | disk is the default (bit-identical); `--vfs:verify` byte-compares every memory read against disk; overhead +0.5 % | `tests/ledger`, `tests/vfs`, `tests/nifcache` |
| 10 | **Stdlib**: `std/syncio` opt-in read log; `std/writenif` writes `<sfx>.out.nif.reads` | `lib/std/syncio.nim`, `writenif.nim` | one `bool` test per open; it is what lets `const x = readFile(...)` notice the file changed (it did not before) | `tests/incremental` phase "ctfe" |
| 11 | **Declaration-stable frontend output** (F1 + F2, on the owner's decision): hexer's synthesized names too (`passes.TempNamer`, `.x.nif` +28 % bytes); a local is spelled `` x`semExpr`0.3 `` (the owning routine joins the identifier, then a per-routine counter) and hexer writes line-info-blind per-declaration digests (`<mod>.decls.nif`) | `sembasics.makeLocalSym`, `symparser`, `hexer/decldigest.nim`; 21 goldens | one dot, so every scanner still classifies it local, and the disambiguator is a number and nothing else, which is what nif-spec #2457 requires (`notes/f1-respell.md`); module-wide uniqueness preserved (found the consumer: `hoistedConsts`); an appended proc changes 1 declaration instead of 465, which is the whole edit-loop gain since B3; costs +31 % artifact bytes and +3 % cold cpu | `tests/symspelling`, and the `decl-stability` scenario in `tests/incremental` |

## Things you may not want (decide these)

- **Defaults changed**: CTFE uses the engine on macOS/arm64 (`--ctfe:auto`);
  `nimony c/n/r` schedule phases in-process (`--spawn:auto`); the blob cache
  is on for native links. Each has the flag above to restore today's
  behaviour; `--vfs` stays `disk`.
- **Binary sizes**: `nimony` links three tools; `nimsem` links arkham and
  nifasm. A booted compiler (compiled by nimony) still spawns `nifmake`, so
  the boot's correctness gate never depends on the scheduler.
- **New process-wide state**: the store, the ledger fragments, the phase
  registry, the engine's two C-ABI globals (`hostrun.gGuest`, the guest I/O
  capture). Each is documented at its declaration; none is reset between
  phases except through the `reset*Globals` procs the tests cover.
- **Memory**: a cold self-compilation's largest process is 147 MB against
  116 MB before. It is one node, `dceLive`, which now holds 127 per-module
  resolve subsets (84 → 147 MB) -- the trade behind P0c's "an edit re-emits
  one module"; streaming them out per module is the follow-up. The scheduler
  budgets in-process work by peak RSS from the ledger (`--inproc-mem-budget`,
  `--stats` shows a `peak MB` column), so the driver itself stays under
  128 MB here.
- **Local symbol spelling** (F1, row 11): `` x`semExpr`0.3 `` is a new shape
  in the symbol namespace. It is no longer argued from the scanners: the
  owning routine rides in the IDENTIFIER and the disambiguator is a number
  and nothing else, which is what nif-spec #2457 requires and what upstream
  spells its own minted names (`` result`i.5 ``, `` write`sys.0.<module> ``).
  `notes/f1-respell.md` records the move and `tests/symspelling` is the gate;
  it checks our spelling against upstream's own parser, vendored, so it holds
  before the merge as well as after. The shape makes `.s.nif`/`.x.nif` 31 %
  larger, and diagnostics render `symparser.sourceIdent` rather than the
  spelling. It is the single change that took the edit loop from 1.26 s to
  0.77 s; everything above stands without it, and reverting it is two commits
  plus the 21 goldens.

## Not done

Hot reload / `nimony dev` (B4), the engine on linux/x64 and Windows (B5,
arkham lacks x64 `&threadvar` lowering under `--dev-single-thread`), an
out-of-process guest (a guest fault kills nimsem today; `--ctfe:subprocess`
is the answer), a `nimNoLibc` arm of `std/rawthreads` on macOS, hexer's
declaration-level incremental `expand` (B3b's last half: F1/F2 made the
inputs and outputs declaration-stable and arkham/nifasm already work per
proc; hexer itself still lowers the whole module, 0.27 s on `sem.nim`, floor
~0.11 s), and declaration-level incremental sem (the 0.34 s re-check of the
edited module; not planned). Streaming `dceLive`'s per-module live sets out
(the 147 MB cold peak) and `--threads:off` for the non-threading tools
(-6 % on hexer) are small items on the list.

## Where this branch sits against upstream

`nim-lang/nimony` master moved six commits past the fork point while this
was built (`nifsyms refactor`, `no globals in nifcore`, `thread the tag
space`, a nativenif re-pin, two sem fixes). A trial merge conflicts in 30
files, mostly the hexer passes F2 renamed and the sem files F1 touched;
`no globals in nifcore` overlaps the intent of A2a's global resets. Local
`master` is fast-forwarded to it; `fast-devloop` is not. `notes/handoff.md`
records the phase-by-phase rebase path and the two gates for it
(`decl-stability`, nativenif's refactor gate).

## Verify in five commands

```
nim c -r src/hastur/hastur build all             # ../nativenif at src/nativenif.commit
bin/hastur boot --boot-backend:native            # stages 1 == 2 == 3
bin/hastur tests/nimony                          # 794/794
bin/hastur test tests/ctfe_diff                  # 0 differences over every mode pair
bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5   # the headline, interleaved (build the fork point into /tmp/devloop_base first)
```
