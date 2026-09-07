# fast-devloop, for review

Branch `fast-devloop` off `master` f69b8afc. Goal: the edit-build-run loop of
the compiler itself, on the native backend, without changing what the
compiler produces. This file is the decision aid; `JIT.md` is the design,
`JIT_IMPL.md` the phase log, `notes/<phase>.md` the details,
`bench/results/*/progress.md` every number with its raw runs.

## Numbers (native backend, interleaved A/B, fork point vs branch)

| scenario | before | after | peak RSS before / after |
|---|---|---|---|
| compiler compiling itself, one body edit in `sem.nim` | 2.78 s | 1.26 s | 116 / 112 MB |
| same edit, then run the compiler from memory (`nimony r`) | no such command | 1.34 s | |
| hello world, edit, build and run | 0.32 s | 0.033 s | 18 / 26 MB |
| one compile-time evaluation (`const` needing a sub-compile) | 450–490 ms, 32 processes | ~27 ms, 0 processes | 59 / 61 MB |
| compiler, no change | 74 ms | 35 ms | |
| compiler, cold | 5.29 s | 5.16 s | 116 / **216 MB** |

Correctness evidence, all automated and green: `hastur boot --boot-backend:native`
stages 1 = 2 = 3 byte-identical; `hastur tests/nimony` 794/794 in every mode;
`tests/ctfe_diff` byte-compares every compile-time result and the calling
module's `.s.nif` across every mode pair (0 differences); nativenif's
`tools/refactor_gate.sh` byte-identical (2583 artifacts). The cold-build
memory increase is the one open regression (last section).

## What changed, one decision per row

Every row keeps the artifacts on disk as they are, adds no optimizer, tier or
speculation (JIT.md 2), and has an escape hatch to today's behaviour.

| # | change | touches | why it is sound | verify with |
|---|---|---|---|---|
| 1 | **Bugs fixed** (P0a/P0c): `-f` was forwarded into every CTFE sub-compile; `runEval` never consulted its own memo; `.live.nif` was hash-ordered so `OnlyIfChanged` never held and every edit re-emitted all modules' `.c.nif` | `nimony.nim`, `semos.nim`, `dce2.nim`, `dce1.nim` | same outputs, fewer re-runs; 127 `.c.nif` byte-identical before/after | `hastur test tests/incremental` |
| 2 | **Ownership rule**: the main module never owns a generic instantiation another module also offers | `dce2.resolveSymbolConflicts` | a shared module's `.c.nif` no longer depends on which main it links with; what makes caches hit | `hastur boot` byte-identical |
| 3 | **Caches**: content-addressed `.o` (`ocache/`), `.c.nif` for CTFE's stdlib closure (`ccache/`), arkham's `asmcache/`, nifasm's per-symbol `blobcache/` | `deps.nim`, `engine.nim`, nativenif `blobcache.nim` | keyed on content + tool stamp; a wrong hit is a loud unresolved symbol, not wrong code; `NIMONY_CCACHE=off`, `--no-blobcache` | `tests/ctfe_engine`, nativenif `tests/tester.nim` |
| 4 | **CTFE on the engine** (B2/A2c): after `.c.nif`, arkham + nifasm in-process into an arena, `main` called; the sub-compile's frontend runs in the parent with its pools snapshotted | `engine.nim`, `semos.nim`, `exprexec.nim`; nimsem links arkham/nifasm (+2.7 MB) | runs arkham's AOT bytes ("CT eval is real compilation"); any `AsmError` falls back to the subprocess; `--ctfe:subprocess`, `NIMONY_CTFE_ENGINE=off`; default `auto` = engine on macOS/arm64 only | `tests/ctfe_diff` (0 differences) |
| 5 | **nativenif as a library** (B1): `generateAsmBuf`, `AsmSession`, `AsmError` instead of `quit`, shared `hostfixup.nim`, `image/memory.nim`, `hostsyms.nim`, `hostrun.nim` | `../nativenif` (pin in `src/nativenif.commit`) | CLI output byte-identical (refactor gate); memory image code hash-equal to the file writer's for 234 fixtures | `tools/refactor_gate.sh` |
| 6 | **Incremental assembly** (B3/B3c): nifasm caches emitted fragments per symbol; foreign procs resolved from their signature | nativenif `blobcache.nim`, `core/declhead.nim` | the DCE worklist is untouched (same pops, same order); sections byte-identical in nine cache states; 127-module warm link 0.84 s → 0.086 s | nativenif `blobcache_selftest` |
| 7 | **`nimony r`** (B1): the native graph minus the link node, assembled in-process, `main` called from the arena | `nimony.nim`, `deps.nim`, `engine.nim` | same graph as `nimony n`; one proc is the run boundary for a later out-of-process guest; `--out` still writes the executable | `tests/nimony_r` |
| 8 | **Tools as procs, nifmake as a library, a scheduler** (A2a/A2b): `runNifler/Nimsem/Hexer/Lengc` + `reset*Globals`; `nifmake/dag.nim`; `nimony` runs a DAG depth in-process when the ledger says its serial cost ≤ a fan-out's | `nimsem/hexer/lengc` entry files, `programs.nim`, `nifpools.nim`, `nifmake/`, `phases.nim`; `nimony` links nimsem+hexer+lengc (2.9 → 4.8 MB) | two runs in one process produce the bytes of two processes (`tests/inproc`); `--spawn:always` / `--vfs:disk` = today's process tree exactly; nifler stays a process | `hastur tests/inproc`, `--report` identical across modes |
| 9 | **Cost ledger + artifact store** (A1): every tool writes `.ledger/` timing fragments, nifmake folds spawn costs, `--stats` prints them; `--vfs:memory\|memory+spill\|disk\|verify` adapter behind `vfs.nim`'s relays | `src/lib/ledger.nim`, `artifactstore.nim`, ~36 call sites moved onto the relays | disk is the default (bit-identical); `--vfs:verify` byte-compares every memory read against disk; overhead +0.5 % | `tests/ledger`, `tests/vfs`, `tests/nifcache` |
| 10 | **Stdlib**: `std/syncio` opt-in read log; `std/writenif` writes `<sfx>.out.nif.reads` | `lib/std/syncio.nim`, `writenif.nim` | one `bool` test per open; it is what lets `const x = readFile(...)` notice the file changed (it did not before) | `tests/incremental` phase "ctfe" |

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
- **Memory**: a cold self-compilation's largest process is 216 MB against
  116 MB before (147 MB with `--spawn:always`). Phase M1 (in flight) puts
  peak RSS into the ledger and makes the scheduler budget it.
- **Frontend output rules** (F1, in flight, on the owner's decision): local
  symbols numbered per declaration and line-info-blind declaration digests,
  so an edit to one proc leaves the other 1226 declarations of `sem.nim`
  byte-identical. It churns goldens; it is the prerequisite for lowering at
  symbol granularity (B3b), which is where the remaining 0.5 s of hexer +
  arkham per edit goes. Everything above stands without it.

## Not done

Hot reload / `nimony dev` (B4), the engine on linux/x64 and Windows (B5,
arkham lacks x64 `&threadvar` lowering under `--dev-single-thread`), an
out-of-process guest (a guest fault kills nimsem today; `--ctfe:subprocess`
is the answer), a `nimNoLibc` arm of `std/rawthreads` on macOS, symbol-
granularity lowering (blocked on F1), declaration-level incremental sem
(the last 0.33 s of the edit loop; not planned).

## Verify in five commands

```
nim c -r src/hastur/hastur build all             # ../nativenif at src/nativenif.commit
bin/hastur boot --boot-backend:native            # stages 1 == 2 == 3
bin/hastur tests/nimony                          # 794/794
bin/hastur test tests/ctfe_diff                  # 0 differences over every mode pair
bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5   # the headline, interleaved (build the fork point into /tmp/devloop_base first)
```
