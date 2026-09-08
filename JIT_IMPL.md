# Fast development workflow — phased implementation plan

Status: implementation plan derived from `JIT.md` (design proposal, revision 2,
2026-09-06). Branch: `fast-devloop`, forked from `master` at `f69b8afc`.
Every phase below is a unit of work that ships alone, has its own tests and a
measurable gate, and names the files it touches so that phases marked as
parallel do not collide.

Conventions used in this document:

- **Owner files**: the files a phase is allowed to change. Two phases that run
  in parallel must have disjoint owner files; shared files are assigned to
  exactly one phase and the other phase codes against the interface written
  here.
- **Tests**: what must be added or extended. Every phase adds tests; a phase
  without a red-to-green test is not done.
- **Gate**: the measurement or invariant that must hold before the phase is
  merged. `hastur tests/nimony` (the tree walk; `hastur test <dir>` runs only that
  directory's own files), `hastur test tests/incremental` and
  `hastur test tests/nifcache` must stay green in every phase; `hastur boot`
  stages must stay byte-identical whenever a phase touches a tool that boots.
- **Verification commands** are given per phase; results are recorded in
  `bench/results/<date>/` (phase 0 creates the directory layout).

The design rationale, measurements and non-goals live in `JIT.md` and are not
repeated. Section numbers in parentheses refer to that document.

---

## 0. Ground truth on this machine (macOS 26, M5, Nim 2.2.10, 2026-09-06)

| scenario | wall |
|---|---|
| `tmyops.nim` (5 consts), cold nimcache | 3.85 s |
| same, no change | 0.011 s |
| same, `-f` | 3.63 s |
| `hastur test tests/nimony/consteval` (5 tests) | 4.7 s |
| `hastur test tests/incremental` (10 phases) | 6.8 s |

Toolchain facts the phases rely on (verified in source):

- `src/lib/vfs.nim` (312 lines): seven relays (`openMmapRelay`, `readBytesRelay`,
  `writeBytesRelay`, `existsRelay`, `mtimeRelay`, `nowRelay`, `removeRelay`),
  `VfsBlob` with cookie + cleanup, atomic replace via `vfsMoveInto`, and a
  `-d:vfsProfile` mode that does not compile (uses `getMonoTime` without
  importing `std/monotimes`).
- Direct OS file calls that bypass the relays: nimony 53, lengc 8, nifler 9,
  hexer 3, nifmake 1 (`grep -E '(readFile|writeFile|fileExists|getLastModificationTime|removeFile|memfiles\.open)\('`).
- `src/nimony/nimony.nim:250`: `of "forcebuild", "f": c.buildFlags.incl ForceRebuild`
  leaves `forwardArg = true`, so `-f` is forwarded to every child `nimony s`.
- `src/nimony/semos.nim:752` `runEval` always runs the sub-program;
  `memoIsStale` (line 614) and `runPlugin` (line 636) are the memo model.
- `src/nimony/exprexec.nim:728` `executeExpr` is the CTFE seam; it ends in
  `rewriteSymsToIdents` + `runEval`.
- CTFE sub-programs are built by `semos.runProgram` spawning `nimony s
  <sfx>.p.nif`, which goes through the ordinary `deps.buildGraph` and
  `generateFinalBuildFile` (`buildGraphForEval` is only reachable from the
  unused `nimsem e`; P0b verified this); `src/nifmake/nifmake.nim:220` `needsRebuild` is the only
  staleness check and it uses `vfsMtime`/`vfsExists` exclusively.
- Tool entry points: `semmain.semcheck(infiles, outfiles, config, ...)`,
  `lengcgen.expand(infile, bits, ..., outdir)`, `dce2.computeLiveSet`,
  `dce2.dceEmit`, `codegen.generateCode(s, inp, outp, flags)`.
- Global state per process: `programs.prog`, `nifpools.pool`,
  `nifpools.globalTags`, `nifcore.fallbackPool`/`fallbackTags`.
- Spawn sites in nimsem: `semos.runProgram` (CTFE), `semos.prepareEval`
  (writenif precompile), `semos.execPlugin`, `macro_plugin.runMacroPlugin`,
  `semos.exec` (plugin builds).
- Track B needs the sibling checkout `../nativenif` at the commit in
  `src/nativenif.commit` (`d0781a48`, 2026-09-05). It is not present on this
  machine yet.

---

## 1. Phase map and schedule

```
wave 1  P0a  cheap wins (-f leak, runEval memo, vfsProfile, ctfe bench)   [worktree]
        P0b  content-addressed .o cache for CTFE sub-programs              [worktree, parallel with P0a]
        B0   nativenif checkout, build, macOS/arm64 tier status, M0        [no repo changes except bench/results]
wave 2  A1a  cost ledger                                                   [parallel]
        A1b  ArtifactStore adapter + relay adoption + --vfs modes          [parallel]
        A1c  CTFE differential harness + consteval corpus                  [parallel]
        A1d  ledger attached to store entries; --stats                     [after A1a+A1b]
wave 3  A2a  buffer-level phase entry points + global reset (per tool)     [parallel per tool]
        A2b  nifmake as a library: phase registry + scheduling rule        [after A2a]
        A2c  CTFE and macro plugins through the in-process path            [after A2b]
wave 4  B1   nativenif as a library + memory image + nimony r from memory  [nativenif repo; after B0]
        B2   engine behind executeExpr                                     [after B1 and A2c]
        B3   per-module code cache, nimrun guest                           [after B2]
        B4   hot reload, nimony dev                                        [after B3]
        B5   macOS/arm64 + Windows dev runtime                             [after B3]
```

Each wave is merged into `fast-devloop` before the next starts. Inside a wave,
phases run in separate git worktrees and are merged one by one after review.

---

## Phase P0a — cheap wins

Goal (JIT.md 9, phase 0): stop the two verified regressions and make the CTFE
latency measurable in the suite.

Owner files: `src/nimony/nimony.nim`, `src/nimony/semos.nim`,
`src/lib/vfs.nim`, `src/nifler/nifler.nim`, `src/nifmake/nifmake.nim`
(only `dumpVfsProfile` calls), `bench/ctfe_bench.nim`, `bench/ctfe_bench.output`,
`tests/incremental/**`, `src/hastur/incrementaltests.nim`,
`bench/results/README.md`.

Steps:

1. **`-f` leak.** In `handleCmdLine`, `forcebuild`/`f`/`ff` set
   `forwardArg = false`. Sub-compiles are content-addressed (module suffix =
   checksum of the expression), so forcing them is never needed. Also stop
   forwarding `ff`.
2. **`runEval` memo.** Before running the sub-program, if
   `<sfx>.out.nif` exists and is newer than `<sfx>.p.nif` (written with
   `writeFileIfChanged` semantics: `writeFileAndIndex` must not touch an
   unchanged `.p.nif`; extend or wrap it) and newer than every file recorded
   by `recordFileDep` for this evaluation (the `.out.nif` written by
   `std/writenif` gets a `(deps ...)` sidecar exactly like plugin outputs, or
   nimsem writes `<sfx>.out.deps.nif` beside it from `c.fileDeps` collected
   during the sub-compile), parse the memoized `.out.nif` instead. Model:
   `runPlugin`'s `needsRecompile` + `memoIsStale`. The memo must also be
   invalidated when the toolchain changes: compare against the mtime of the
   `nimsem` executable (`getAppFilename`) the same way `needsRecompile` does
   for plugins. Also write `.p.deps.nif` with `writeFileIfChanged`.
3. **`-d:vfsProfile`.** Import `std/monotimes` under the define; call
   `dumpVfsProfile` at exit of every tool that lacks it (nifler, nifmake,
   niflink; check which already call it); make the profile build compile
   (`nim c -d:vfsProfile src/nimony/nimsem.nim` etc.).
4. **`bench/ctfe_bench.nim`.** A benchmark in the `bench/` convention
   (`when smoke:` shrinks the workload; deterministic output): N fresh
   `const`s that each need a sub-compile (a proc call, a `@[]`, a `Table`,
   a string builder), printing a checksum of the results. Its `.output`
   golden is the smoke output. Under `-d:benchSmoke` it prints only the
   checksum. The *latency* measurement is external: a script
   `bench/ctfe_latency.sh` (or a `hastur` subcommand if one fits) that runs
   `bin/nimony c -f --report bench/ctfe_bench.nim` on a fresh nimcache,
   reports wall time and the process count from `--report`, then runs it
   again for the repeat number.
5. **`bench/results/`**: `README.md` describing the layout
   `bench/results/<YYYY-MM-DD>/<benchmark>.txt` with the header fields from
   JIT.md 12 (commit, OS, Nim version, mode). Record the P0 before/after
   numbers there.

Tests:

- `tests/incremental`: extend `incrementalTests` with a CTFE scenario: a
  module with a `const` needing a sub-compile compiles cold; a second run
  executes zero nifmake commands; a *content-preserving* touch of the source
  reruns nifler and nothing else; after the fix `-f` on the outer compile
  must not re-run the sub-program's build nodes (assert via the process count
  from a `--report` line emitted by the inner `nimony s`; add
  `nifmake-report` forwarding for the child if it is not visible). Also: edit
  a file read by the `const` (`slurp`/`readFile` inside the evaluated
  expression) and assert the sub-program is re-run (memo invalidated).
- `bench/ctfe_bench.nim` under `hastur test bench` (smoke).

Gate:

- repeat evaluation ≤ 2 ms per const (measured by the latency script:
  warm `nimony c` of `ctfe_bench.nim` with an unchanged file is dominated by
  nifmake, and the inner `nimony s` reports 0 commands and no exec).
- new evaluation ≤ 0.36 s per const on this machine (was 0.45–0.49 s).
- `hastur test tests/nimony tests/incremental tests/nifcache` green.

## Phase P0b — content-addressed object cache for CTFE sub-programs

Goal (JIT.md 3.3, 9): 7 of 8 object files of every CTFE sub-program are
byte-identical across sub-programs and are recompiled every time.

Owner files: `src/nimony/deps.nim` (only `buildGraphForEval` and the helpers
it calls that are not shared with `buildGraph`), `src/hexer/dce2.nim`
(`resolveSymbolConflicts`), `src/hexer/lengcgen.nim` if needed for stable
output, `tests/hexer/**` for new goldens, `tests/incremental/**` (a new
scenario file, not the ones P0a edits — coordinate: P0b adds
`tests/incremental/ctfe_ocache.nim` and asserts through its own runner proc
in `src/hastur/incrementaltests.nim`; P0a owns `incrementalTests`, P0b adds
`incrementalOCacheTests` and the `setup.nim` call).

Steps:

1. Confirm the duplication: after compiling `tconstseq.nim`, hash the `.c`
   and `.o` files of two sub-program directories and list which differ and
   why (the expected answer: only the main module and whatever
   `resolveSymbolConflicts` re-owned).
2. Make `resolveSymbolConflicts` prefer a stable non-main owner for a symbol
   that appears in several modules, so a module's `.c.nif` does not depend
   on which main module it is linked with.
3. In `buildGraphForEval`, route the non-main modules' `lengc` → `cc` nodes
   through content-addressed outputs: `<nimcache>/ocache/<sha of .c.nif +
   cc flags>.o`; the link node consumes those. The cache directory is
   shared by all sub-programs. Keep the `.c` beside the `.o` for
   inspection.
4. Bound the cache: no eviction in this phase, but a `nimony clean`-style
   note in the README; the cache lives inside `nimcache/` so `hastur clean`
   removes it.

Tests:

- `tests/incremental/ctfe_ocache.nim` + runner: two modules each with a
  `const` that needs a sub-compile; after the first compiles, the second's
  `--report` shows `cc` ≤ 1 (main module only) and `link` = 1.
- Hexer goldens re-recorded with `hastur --overwrite test tests/hexer` only if
  step 2 changes them; the diff is part of the review.

Gate: second sub-program of a run compiles with one `cc`; `hastur test
tests/nimony tests/hexer tests/incremental` green.

## Phase P0c — an edit re-emits only the modules whose live set changed

Goal (found by the self-compilation benchmark, `bench/results/2026-09-06/progress.md`
run 4): a one-line edit to `sem.nim` re-runs `dceEmit` for all 127 modules
(1.6 s CPU, ~0.4 s wall) because `dceLive` rewrites the whole-program
`<main>.live.nif` on every build, even when the live set is unchanged (a
body-only edit). Owner files: `src/hexer/dce2.nim`, `src/hexer/hexer.nim`
(`dl` output), the `dceLive`/`dceEmit` node emission in
`src/nimony/deps.nim` (`generateFinalBuildFile`, minimal hunks),
`tests/incremental/**`, `src/hastur/incrementaltests.nim` (a new scenario
proc).

Steps: (1) `dceLive` writes one `<mod>.live.nif` per module (its resolve
entries and live set) with `OnlyIfChanged` semantics, plus the whole-program
file if anything still reads it; (2) each `dceEmit` node's input is its own
module's live file, so nifmake re-runs it only when that file moved;
(3) `dceEmit` output is written `OnlyIfChanged` too, so `lengc`/`cc` of an
unchanged module stay put.

Tests: an incremental scenario on a 3-module fixture: a body-only edit of
a leaf module re-runs `dceEmit` for that module only and `cc` for it only;
an edit that changes what is live in an importer re-runs exactly the
affected modules; `tests/incremental`, `tests/inproc`, `tests/ctfe_diff`,
`tests/nifcache` green; `hastur boot` byte-identical.

Gate: `self.editbody` on the self-compilation benchmark drops by the
dceEmit fan-out (~0.3–0.4 s wall) with `cc` count 1; `self.cold` within 3 %.

## Phase B0 — nativenif on this machine and the M0 measurement

Goal (JIT.md 9, phase 0 track B; B1 "M0 measurement first"): know where
macOS/arm64 stands before committing to the engine.

Owner: `../nativenif` (checkout only), `bench/results/<date>/native_*.txt`.
No source changes in nimony.

Steps:

1. `git clone https://github.com/nim-lang/nativenif ../nativenif` and check
   out the pin from `src/nativenif.commit`; `nim c -r src/hastur/hastur build
   native` (or `build all`).
2. `hastur tiers native` on this machine; record the per-module pass/fail
   table and the first failing module's error class per tier.
3. M0: for the 8 `.c.nif` modules of one CTFE sub-program under `nimcache/`
   and for the stdlib-wide corpus, time `arkham --os:macosx --cpu:arm64` per
   module and `nifasm` on the image, three runs each, median. Record in
   `bench/results/<date>/native_m0.txt` with the tool commit.
4. Verify the two memory-mapping facts from JIT.md 7.1 with a 30-line Nim
   program: `mmap` RW → `mprotect` RX → call, and `MAP_JIT` +
   `pthread_jit_write_protect_np`. Record which works for an unsigned binary
   built by `nim c`.

Gate: a written status in `bench/results/<date>/native_status.md`: tier
count on macOS/arm64, M0 numbers, mapping facts. This decides B1's platform
order (linux/x64 first is the default; if macOS/arm64 passes the tiers it
moves first because it is where development happens).

---

## Phase A1a — the cost ledger

Goal (JIT.md 5.2): every artifact carries its produce/serialize/write/load/
parse/spawn timings, aggregated per (phase, module, toolhash) with an EWMA,
persisted across runs.

Owner files: new `src/lib/ledger.nim`, new `src/lib/toolhash.nim`,
`src/nimony/nimsem.nim`, `src/hexer/hexer.nim`, `src/lengc/lengc.nim`,
`src/nifler/nifler.nim` (entry-point instrumentation only),
`src/nifmake/nifmake.nim` (record per-command wall time into the ledger;
this is where `spawn` and `produce` for spawned phases are known),
`tests/nifcache/**` or a new `tests/ledger/` with a `setup.nim` runner.
Not owned: `src/lib/vfs.nim` (A1b owns it; A1a reads timings through the
public procs A1b exposes, see interface below).

Interface (written here so A1b and A1d can code against it):

```nim
# src/lib/ledger.nim
type
  LedgerKey* = object
    phase*: string      # "nifler" | "nimsem" | "hexer" | "dceLive" | "dceEmit" | "lengc" | "cc" | "link" | ...
    module*: string     # module suffix, "" for whole-program nodes
  LedgerSample* = object
    produceNs*, serializeNs*, writeNs*, loadNs*, parseNs*, spawnNs*: int64
    bytes*: int64
  LedgerEntry* = object
    ewma*: LedgerSample  # exponentially weighted, alpha 0.3
    samples*: int
    updated*: int64      # unix ns
    toolhash*: string
  Ledger* = object       # in-memory table + dirty flag

proc openLedger*(path: string): Ledger     # path: <nimcache>/ledger.nif; missing file => empty
proc record*(l: var Ledger; key: LedgerKey; s: LedgerSample; toolhash: string)
proc estimate*(l: Ledger; key: LedgerKey): LedgerSample   # falls back to phase-wide mean, then to a default table
proc saveLedger*(l: var Ledger)             # atomic write via vfsWrite; NIF text (ledger (entry ...)*)
proc toolhash*(): string                    # src/lib/toolhash.nim: hash of the running tool's executable (size + mtime + path), cached
```

NIF shape of the file is the one in JIT.md 5.2 with one `(entry ...)` per
key. Per-artifact sidecars are **not** written in this phase: one ledger
file per nimcache is simpler and is what nifmake reads; A1d revisits
sidecars if the store needs them.

Steps:

1. `ledger.nim` + `toolhash.nim` with unit tests (host Nim `nim c -r`
   under `tests/ledger/`, and a smoke compile under nimony).
2. Instrument the tools: each `handleCmdLine` records `produce` (wall time
   of the phase proc), `serialize` (time inside the final `toString`/
   `storeToString`), `write` (time in `vfsWrite`, from vfs's profile
   counters when built with `-d:vfsProfile`, else measured around the call),
   `load` + `parse` (time around `vfsOpenMmap` + `parse` of the main input).
   Tools append to `<nimcache>/ledger.nif`; concurrent tools from `nifmake
   -j` must not corrupt it: each tool writes `<nimcache>/ledger/<phase>_<module>.nif`
   (atomic replace, no lock) and `openLedger` folds the directory into the
   table. nifmake merges the directory into `ledger.nif` at the end of a run.
3. nifmake records `spawn` for each command as (wall − the tool's own
   reported `produce`) when the tool's fragment exists, else wall.
4. `--stats` in nimony prints the per-phase table from the ledger
   (count, ewma produce, ewma spawn, ewma serialize+parse, bytes).

Tests:

- `tests/ledger/setup.nim`: unit tests for EWMA, fallback estimate,
  round-trip through NIF, merge of fragments, toolhash reset (an entry
  recorded under another toolhash is ignored by `estimate`).
- An integration scenario in the same runner: compile a small program twice;
  assert the ledger has entries for nifler, nimsem, hexer, dceEmit, lengc,
  cc, link and that `samples` increments.

Gate: `--stats` shows a per-phase table after `nimony c -f`; ledger
overhead ≤ 1 % of a forced hello-world build (measure with and without).

## Phase A1b — ArtifactStore adapter, `--vfs` modes, relay adoption

Goal (JIT.md 5.1): an in-memory VFS adapter behind the relays with policies
`memory`, `memory+spill`, `disk`; `--vfs:disk` is the escape hatch;
`--vfs:verify` runs both and compares.

Owner files: `src/lib/vfs.nim`, new `src/lib/artifactstore.nim`, the
direct-OS-call sites listed in section 0 in `src/nimony/**`, `src/hexer/**`,
`src/lengc/**`, `src/nifler/**`, `src/nifmake/nifmake.nim` (relay adoption
and a `runNodeRelay`), `src/nimony/cli.nim` (`--vfs` option, forwarded),
`tests/nifcache/**` (extend the existing runner), new `tests/vfs/`.

Design constraints (all from JIT.md 5.1):

- Entry: path → {repr: text bytes | bif blob | resident TokenBuf, generation,
  size, spilled, policy}. Readers get a `VfsBlob` whose cookie pins the entry
  (refcount); entries are replaced, never mutated (PR #2396 invariant).
- `mtimeRelay` on a memory entry returns its generation stamped into the
  same int64 nanosecond space (`nowRelay()` at write time), so `needsRebuild`
  is untouched.
- Write-through set: `.s.idx.nif`, `.x.nif`, `.s.deps.nif`, `.p.deps.nif`,
  `.build.nif`, plugin `.out.nif`, ledger files, and anything under
  `ocache/`. Everything else follows the policy. A table of suffix → policy
  lives in `artifactstore.nim` and is the single place to read for "what is
  in memory".
- `--vfs:disk` installs no adapter at all (bit-identical to today).
- `--vfs:verify` installs the adapter and, on every read of a memory
  entry, also reads the on-disk copy (the store writes through in this
  mode) and compares bytes; a mismatch is a fatal diagnostic naming the
  path.
- Budget: `--vfs-budget:<MB>` (default 512); above it, the store spills the
  largest entries whose policy allows it. The ledger-driven policy is A1d.

Steps:

1. `artifactstore.nim`: the store, the adapter installer
   `installArtifactStore(policy)`, `spillAll(dir)` (for `--dump` and for
   handing inputs to a spawned process), `storeStats()`.
2. Relay adoption: replace the ~74 direct calls with `vfsRead`/`vfsWrite`/
   `vfsExists`/`vfsMtime`/`vfsRemove`/`vfsOpenMmap`. Where a call is not a
   file-content operation (`getAppFilename`, `createDir`, `walkDir`,
   `moveFile` of executables), leave it and list it in a comment block at
   the top of `artifactstore.nim` as intentionally outside the store.
3. `nifmake`: `runNodeRelay*: proc (cmd: Command): bool` used by `runDag`
   for both the sequential and the `execProcesses` paths (the parallel path
   calls it per command inside the batch; the relay decides). Default:
   today's `executeCommand`. This is the seam A2b fills.
4. `--vfs:memory|memory+spill|disk|verify` parsed in `cli.nim`
   (`parseCommonOption`), forwarded to every tool; default stays `disk`
   until A2c flips dev commands to `memory` (a store per process is only
   useful once phases share a process).
5. Because the default is `disk`, the adapter must be exercised by tests
   with `--vfs:memory` and `--vfs:verify` explicitly.

Tests:

- `tests/vfs/setup.nim` (host Nim unit tests over `artifactstore.nim`): put/
  get/replace/generation/spill/budget/verify-mismatch; blob lifetime (a blob
  held across a replace still reads the old bytes).
- `tests/nifcache` runner: whole-suite comparison — compile
  `tests/nimony/stdlib/tall.nim` with `--vfs:disk` and with
  `--vfs:verify`; the verify run must complete with no mismatch. A cheaper
  per-PR form runs it on `tests/nimony/consteval` and `tests/incremental`'s
  sample.
- `tests/incremental`: run the existing scenarios under `--vfs:memory+spill`
  as well (parametrize the runner with a mode list).

Gate: `--vfs:disk`, `--vfs:memory+spill` and `--vfs:verify` produce
byte-identical artifacts on `tests/nimony` and `tests/incremental`; no
mismatch in verify mode; `hastur boot` unchanged (default mode is `disk`).

## Phase A1c — CTFE differential harness and consteval corpus

Goal (JIT.md 9, A1): the oracle for every later CTFE change.

Owner files: `tests/nimony/consteval/**` (new tests), new
`tests/ctfe_diff/setup.nim` + `src/hastur/ctfediff.nim` (runner), `JIT_IMPL.md`
(this section's status).

Steps:

1. Grow `tests/nimony/consteval/` to cover: seq of int/string/object, string
   building, `Table`, object with nested object, array, tuple, enum, set,
   distinct, `ptr UncheckedArray` fields, empty `@[]`, a proc with a `var`
   parameter, a `for` over a seq, a `case`, a `const` referencing another
   `const`, `sizeof`-dependent values, float arithmetic, and the failure
   modes (a `const` whose evaluation raises: expect a compile error with the
   message; a `const` reading a missing file). Each test has an `.output`
   golden or `.msgs` for the error cases. Use `hastur --overwrite test
   tests/nimony/consteval` and review the goldens.
2. `ctfediff` runner: for every `.nim` under a directory list, compile with
   mode A and mode B (initially `--vfs:disk` vs `--vfs:memory+spill`; later
   `--ctfe:subprocess` vs `--ctfe:engine`), collect every
   `<sfx>.out.nif` under the two nimcaches and compare byte for byte; report
   the first differing token with the test name. Modes are CLI options of
   the runner so B2 reuses it unchanged.
3. Wire into the tree walk: `tests/ctfe_diff/setup.nim` runs the harness on
   `tests/nimony/consteval` with the two modes that exist at the time.

Tests: the phase *is* tests. The runner has a self-test: a deliberately
different `.out.nif` in a temp dir must be reported.

Gate: every consteval test passes; the harness reports zero differences
between `--vfs:disk` and `--vfs:memory+spill` once A1b lands (until then it
runs disk vs disk and must report zero).

## Phase A1d — ledger meets store; `--stats`; spill policy

Goal: the two pieces of A1 use each other (JIT.md 5.2 "what the ledger is
used for").

Owner files: `src/lib/artifactstore.nim`, `src/lib/ledger.nim`,
`src/nimony/nimony.nim` (`--stats` output), `tests/vfs/**`, `tests/ledger/**`.

Steps:

1. Store entries carry a `LedgerSample` for load/parse; `vfsOpenMmap` and
   `vfsRead` on a store entry record `load`; parse time is recorded by the
   tools at the parse call and attributed to the path.
2. Spill policy: spill an entry when the budget is exceeded, its resident
   size is largest, and `load + parse` estimate < `produce` estimate ×
   margin (default 0.5); never spill what is cheaper to recompute.
3. `--stats` prints the store table (resident bytes, spilled count, verify
   mismatches = 0) beside the phase table.

Tests: unit tests for the spill decision with synthetic ledger entries.

Gate: `--stats` on a forced `tall.nim` build prints both tables; the
decision table in the test is exhaustive over the (budget, cost) cases.

---

## Phase A2a — buffer-level phase entry points and global reset

Goal (JIT.md 6.1): every phase callable as a proc in one process.

This phase is three independent sub-tasks, one per tool, each in its own
worktree:

- **A2a-hexer**: `src/hexer/**`. `expand` gets a `TokenBuf`/`Cursor` overload
  that returns the `.x.nif` buffer without touching files; `computeLiveSet`
  and `dceEmit` get overloads over buffers with the `resolved` table
  exposed as a reusable object; `hexer.handleCmdLine` becomes a thin shell
  over a `runHexer(args: seq[string]): int` proc; `resetHexerGlobals()`
  documents and resets every module-level `var` (list them in the proc).
- **A2a-lengc**: `src/lengc/**`. `generateCode` over buffers;
  `runLengc(args): int`; `resetLengcGlobals()`.
- **A2a-front**: `src/nimony/nimsem.nim`, `src/nimony/semmain.nim`,
  `src/nifler/**`, `src/nimony/programs.nim`, `src/lib/nifpools.nim`.
  `runNifler(args): int` and a `parseToBuf(path): TokenBuf`;
  `runNimsem(args): int`; `resetFrontendGlobals()` resets `prog`, `pool`,
  `globalTags`, `fallbackPool`/`fallbackTags`, identstyle tables and every
  other module-level `var` found by `grep -n '^var' src/nimony/*.nim
  src/lib/*.nim` (the list goes into the proc's doc comment). Re-entrant
  sem for the CTFE snippet reuses `semmagics.semCompiles`'s save/restore
  set; if that set is insufficient, the snippet's sem runs after a full
  reset with the parent's state saved and restored around it.

Each sub-task keeps its CLI byte-identical: `hastur test` for its area
and, for A2a-front, `hastur boot` byte-identical.

Tests per sub-task: a host-Nim unit test that runs the tool's `run*` proc
twice in one process on two different inputs and asserts the outputs equal
the outputs of two separate processes (`tests/inproc/setup.nim`, one runner,
three sections).

Gate: the three `run*` procs exist, the reset procs are tested, the suite
and the boot are green.

## Phase A2b — nifmake as a library: phase registry and the rule

Goal (JIT.md 6.1–6.2): `nimony` runs the DAG in-process where the ledger
says spawning is not worth it.

Owner files: `src/nifmake/nifmake.nim` (split into `nifmake/dag.nim`
library + CLI), new `src/nimony/phases.nim` (registry), `src/nimony/deps.nim`
(build-graph driver calls the library instead of spawning `nifmake` when
in-process mode is on), `src/nimony/nimony.nim` (`--jobs`, `--spawn:always`,
links the tools' `run*` procs), `src/nimony/nimony.nim.cfg`/`nim.cfg` if
link size needs flags, `tests/incremental/**`.

Steps:

1. `dag.nim`: DAG parse, topo sort, `needsRebuild`, `runDag` with the
   `runNodeRelay` from A1b; the `nifmake` CLI is a 60-line shell.
2. `phases.nim`: `registerPhase(name, proc (cmd: Command): int)`; the
   registry maps `nifler`, `nimsem`, `hexer`, `dceLive`, `dceEmit`,
   `lengc` to the `run*` procs from A2a; `cc`, `link`, `arkham`, `nifasm`,
   `niflink`, plugins, external tools are unregistered (always spawn).
3. The rule of JIT.md 6.2 with `spawnCost` from the ledger (`estimate` for
   key `(phase, module)`, default 3 ms), `k = 3`, cores from
   `countProcessors()`. `--jobs:1` forces sequential; `--spawn:always`
   forces spawning while keeping the store; `--vfs:disk` implies
   `--spawn:always`.
4. In-process nodes run sequentially with `reset*Globals()` before each;
   spawned nodes have their inputs spilled first (`spillAll` on the node's
   inputs).
5. nimony runs the two build graphs through the library in the same
   process; `--report` keeps its format (in-process nodes count as
   executed commands, with an `inproc=` field added).

Tests:

- `tests/incremental`: the existing scenarios under `--spawn:always` and
  under the default; assert identical `--report` counts and identical
  artifacts (hash `nimcache/`).
- A scenario asserting `inproc` > 0 and `spawned` = cc + link only for the
  one-module edit.

Gate: zero spawns before `cc` for a one-module edit of hello world; cold
stdlib-wide build within 10 % of today's wall time (fan-out still happens
for cc); `hastur boot` byte-identical in both modes.

## Phase A2c — CTFE and macro plugins through the in-process path

Goal (JIT.md 6.3): a `const` costs no spawn before `cc`.

Owner files: `src/nimony/exprexec.nim`, `src/nimony/semos.nim`
(`runEval`, `runProgram`, `prepareEval`), `src/nimony/macro_plugin.nim`,
`src/nimony/deps.nim` (`buildGraph` for `.p.nif` projects → library call), `tests/ctfe_diff/**`.

Steps:

1. `runEval` builds the eval graph and runs it through the DAG library in
   the current nimsem process (nimsem now links the hexer and lengc `run*`
   procs); only `cc`, `link` and the exec spawn.
2. The writenif precompile in `prepareEval` goes through the same path.
3. `runMacroPlugin` call sites become buffer handoffs when the plugin is
   registered in-process (the file protocol stays available and is the
   fallback).
4. Dev commands (`nimony c` without `--vfs`) default to `memory+spill`.

Tests: the differential harness runs `--spawn:always --vfs:disk` vs the
default and reports zero differences over the consteval corpus; the
incremental CTFE scenario asserts the inner report has `inproc` = all
frontend nodes.

Gate: new CTFE evaluation ≤ 0.2 s; repeat ≤ 2 ms; consteval, incremental,
nifcache, ctfe_diff green; `hastur boot` byte-identical.

---

## Phase B1 — nativenif as a library; `nimony r` from memory

Repository: `../nativenif` (changes there are their own PRs; this repo
re-pins `src/nativenif.commit` via `hastur update deps`). Items 1–7 of
JIT.md 7.1, each a commit gated by `tools/refactor_gate.sh` in nativenif:

1. `generateAsmBuf(buf, target): TokenBuf` beside `render`; one shared asm
   tag pool.
2. `AsmSession`: `openSession`, `addMainModule`, `declare`, `beginEmit`,
   `emitRoots(roots)`, `finishCode`, `synthesizeProcessEntry`.
3. `diagnostics.error` raises `AsmError`.
4. `image/memory.nim` + `image/hostfixup.nim` shared with the file writers.
5. `core/hostsyms.nim` resolver.
6. Direct `main.0` call; intercept `cExit`.
7. `--dev-single-thread` thread-local lowering.

In this repo: `nimony r` (new command, `src/nimony/nimony.nim`,
`src/nimony/deps.nim`) bypasses the link node and runs `main` from the
arena via a new `src/nimony/engine.nim` that links nativenif's library
modules (path from `deps.nim`'s `NativenifDir`).

Tests: in nativenif, arena bytes hash-equal to the ELF/Mach-O writer's code
for every file in its test corpus; in nimony, `tests/nativecg` and the
native regression set through `nimony r`.

Gate: `nimony r` of the stdlib-wide test runs with no linker on the first
qualified platform; refactor gate green; `hastur native` green.

## Phase B2 — the engine behind `executeExpr`

Owner: `src/nimony/exprexec.nim`, `src/nimony/engine.nim`, `src/nimony/cli.nim`
(`--ctfe:subprocess|engine`), `tests/ctfe_diff/**`.

Steps: engine path = sem in-process → hexer in-process → resolve → arkham →
nifasm one module → map, call, read back through `writenif` bound to a
memory buffer; fall back to the sub-compile on `AsmError`/`Defect`;
per-proc on-disk code cache keyed by Leng checksum + toolhash; stdlib
closure compiled on demand via `emitRoots`; fresh allocator region per
evaluation; intercept `cExit` and `write(2, …)`; step and allocation
budgets.

Tests: `ctfediff` with modes `--ctfe:subprocess` vs `--ctfe:engine`, zero
differences; budget tests (a runaway `const` is a diagnostic).

Gate: new evaluation ≤ 30 ms on the qualified platforms; arena bytes
hash-equal to the file writer; `hastur boot` green with the engine in the
loop.

## Phase B3 — module code cache and `nimrun` guest

Blob format (code, data, bss size, symbol table, needed symbols, fixups,
TLS layout), key = SHA-1 of `.x.nif` + flags + tool build id + layout hash;
`nimrun` out-of-process guest over a pipe; `.x.nif` feed with the cached
resolve step; frozen-vs-reloadable slot policy; blob load/fixup in the
ledger.

Gate: cold `nimony r` of the stdlib-wide test loads cached modules in ≤ 20
ms; a one-line edit runs in ≤ 40 ms end to end.

Status (see the table at the end): the code cache half is done, in nativenif
(`jit/b3`) and wired into both native paths here (`jit/b3-nimony`,
`notes/b3-nimony.md`, `bench/results/2026-09-06/b3n.txt`). Three items of the
paragraph above are NOT done and are carried into B4, because measurement
moved them there:

* **the `nimrun` out-of-process guest.** Nothing in the numbers asks for it
  yet: a `nimony r` process runs one program and exits, so the parked thread
  B1 accepted still costs milliseconds. It becomes necessary when a program is
  re-run without a fresh compiler process, i.e. with `nimony dev`. **Built in
  B4 stage 1** (`notes/b4.md`), and it is that phase's step 1 rather than a
  footnote: measured here, fifty in-process runs from one host process leave
  fifty-one parked threads and 13.6 GB of mapped address space, against one
  thread and no growth through `nimrun`.
* ~~**the `.x.nif` feed with the cached resolve step.**~~ **Struck: absorbed
  by B3c and B3d.** The justification -- "318 ms of a warm 484 ms compiler link
  is `blobResolve` + `blobRefs`" -- **double-counted**: `blobRefs` ⊇
  `blobResolve` (`nativenif/notes/b3c.md:43-44`, `blobRefs` is `replay`'s whole
  per-reference loop and `blobResolve` the nested first-sighting
  `lookupWithAutoImport` inside it), so the real figure was ~163 ms of 478, not
  318 of 484. B3c's `core/declhead.nim` -- which IS "the cached resolve step"
  under another name -- then cut the pair to 19.6 / 25.9 ms
  (`b3c.md:177-178`), and B3d took the comparable `sem.nim`-edited link from
  0.32 s to 0.12 s. Resolution inside it is now on the order of 26 ms, under
  3 % of the 1.02 s live-edit headline. Not a phase; at most a small item.
* **the frozen-vs-reloadable slot policy.** Every call a replayed fragment
  makes is still a direct branch patched from the final label table ("frozen
  module → load-time direct patch", JIT.md 7.3). The indirection a reloadable
  module needs is B4's by definition. Note what is missing is the POLICY: the
  `extproc` slot mechanism JIT.md 7.3 points at is implemented and exercised on
  BOTH targets already -- arm64 through `emitA64Stub`
  (`nativenif/src/nifasm/image/hostfixup.nim:79-98`), x86-64 through
  `rkIatCall`'s `call [rip+d32]` (`.../image/memory.nim:185-194`). What B4 adds
  is which modules are reloadable, a swap API and the generation counter.

The cache key is also not literally the SHA-1 of the `.x.nif`: nifasm keys a
blob on target + flags + tool build id + module NAME and validates it with a
file stamp first and a content hash second, because hashing a 50 MB corpus
costs a third of the budget the whole incremental link has. `--blobcache-hash`
restores the letter of the paragraph at that price. `notes/b3.md` §3.2 in
nativenif argues it.

## Phase B3b — symbol-granularity lowering for the edited module

Goal: after B3, a body edit in the compiler's largest module still re-lowers
the whole module: hexer 0.36 s, arkham 0.41 s (run 6). JIT.md 7.3 already
says "compile at symbol granularity for the edited module"; this phase does
it before hot reload needs it.

Steps: (1) hexer's `expand` keeps the previous `.x.nif` and re-lowers only
the top-level declarations whose sem output changed (declaration-level diff
of the `.s.nif`, keyed by symbol; the inliner's cross-proc effects are the
hard part -- a changed inline body invalidates its callers); (2) arkham per
symbol with B3's fragment cache keyed on the symbol's Leng (already the
cache unit in nifasm; arkham needs the same split: emit only the changed
procs' asm-NIF and splice the rest from the previous `.asm.nif`); (3) the
same per-declaration diff feeds the `.dce.nif` analysis so `dceLive` stays
cheap.

Gate: `self.editbody` hexer + arkham time for a body edit in `sem.nim` ≤ 0.1 s;
`.x.nif`/`.asm.nif` byte-identical to a full re-lowering (the differential
harness idea applied to lowering); boot byte-identical.

Open decision (project owner): the remaining 0.45 s of `nimsem` on that
module is the per-module re-check. Declaration-level incremental sem is
outside JIT.md's "no new compiler technology" scope and is the only lever
left for it.

Status: step 2 (arkham) built in B3e; steps 1 and 3 (hexer, dceLive) are H1's.
Previously: measured twice, built neither time. The second attempt (after F1,
branch `jit/b3b`, `notes/b3b.md` §10-15) found that the gate's own benchmark
no longer exercises arkham or the linker at all, and that hexer's module-wide
temp counters make the splice unsound in BOTH directions along the module.
The ordered prerequisite is now step 3 of `notes/b3b.md` §14 — scope
`Pass.nextTemp` and `intramodinliner`'s counter per top-level declaration —
and nothing in this phase pays before it. The gate should also be restated on
an edit that survives DCE: `self.editbody` appends a private, never-called
proc, so its measured arkham + link cost is 0.000 s.

## Phase F1 — declaration-stable frontend output (B3b's prerequisites)

Decision (project owner, 2026-09-07): do the prerequisites. This is the first
phase that changes the frontend's output rules, outside JIT.md's original
"no new compiler technology" line; the owner accepted that for the
incremental loop's sake.

Goal: an edit to one declaration of a module changes that declaration's
`.s.nif`, `.x.nif` and `.asm.nif` output and nothing else's, so B3b's
declaration-level hexer/arkham and nifasm's per-symbol cache see one stale
symbol instead of 465 (`notes/b3b.md`, the `decl-stability` scenario).

Steps, in order, each gated by the `decl-stability` ratios:
1. **Per-declaration local numbering in nimsem**: `sembasics.makeLocalSym`
   numbers locals from a module-wide per-name counter; number them within
   the enclosing top-level declaration instead, in a form the NIF naming
   rules allow (AGENTS.md: follow the NIF standard for temporaries; research
   nifspec's symbol rules before choosing the spelling). Goldens churn: every
   `.nif` golden with local names; `hastur --overwrite`, diff reviewed.
2. **Line-info-blind identity**: hexer (and the `.dce.nif` analysis) digest a
   declaration with line info masked, and re-base line info on a spliced
   fragment; `.x.nif` bytes stay identical to a full lowering.
3. Then B3b proper: per-declaration fragments for hexer's module-wide tables,
   an intra-module inline dependency map, full re-lowering as fallback;
   proc-scoped labels/rodata/temps in arkham so unchanged procs emit
   byte-identical asm; per-symbol blob validity in nifasm.

Gate for F1 (steps 1-2): `decl-stability` reports ≤ 3 changed declarations
for the appended-proc edit and 1 for the in-place edit (was 465 / 1);
`hastur tests/nimony`, `tests/incremental`, ctfe_diff green; native boot
byte-identical; `self.editbody` not worse.

## Phase B4 — hot reload and `nimony dev`

Built on **macOS/arm64**, which is the platform with the evidence behind it.
JIT.md 7.4's "(x64 first)" is inherited from a B1 premise B0 formally
overturned (`bench/results/2026-09-06/native_status.md:242-245`) and both
halves of that premise are false in the built system: the symbol resolver uses
`dlsym` on every POSIX host (`nativenif/src/nifasm/core/hostsyms.nim:123-145`),
and the "existing TLS mechanism" is precisely what x86-64 lacks under
`--dev-single-thread` -- `emTvarAddr` (`.../src/arkham/x64/mem.nim:210-284`)
unconditionally names `arkham.tls.self.0`, which nifasm never lays down in that
mode, while arm64's `genTvar` asks the question itself
(`.../src/arkham/risc/driver.nim:189-221`) and `grep -rn "oneThread"
src/arkham` hits nothing under `x64/`. **x86-64 is the blocked target, not the
ready one**, and unblocking it is B5's.

Steps, in order:

1. **the `nimrun` out-of-process guest** (carried out of B3, above). It is
   what gates the gate: `hostrun.guestExit` parks the thread that called `exit`
   forever, so an in-process `dev` accumulates a thread and a 256 MB arena per
   run and can never stop a program it is about to replace. Platform-neutral.
   **Done** -- `src/nimony/guestwire.nim`, `src/nimony/nimrun.nim`,
   `engine.runWholeProgramOutOfProcess`, `nimony r --guest:subprocess`,
   `tests/inproc/guest`; `notes/b4.md`.
2. **layout sidecar and classifier** (safe/unsafe edit). Platform-neutral, and
   materially cheaper than when JIT.md was written: F1/F2 built line-info-blind
   per-declaration digests (`src/hexer/decldigest.nim`, `<mod>.decls.nif`), B3d
   built the asm-side twin (`nativenif/src/arkham/core/asmdecls.nim`), and
   B3e's fragment key already folds in every proc SIGNATURE -- which is most of
   an interface checksum.
3. **slot swap with generation counter.** Policy, not mechanism; see the B3
   bullet above.
4. **the trace-table stack walk.** `notes/b4.md` §1a settles whose stack it
   is: the table's `cfaOff` is valid only past the prologue
   (`nativenif/src/nifasm/image/tracetable.nim:36-39`), so no asynchronous seed
   can start it -- the walk is synchronous, in the guest's address space,
   seeded by a call the guest made. Two ways to build it, argued there: a
   guest-side self-walk, which is `lib/std/stacktraces.nim` and needs two RISC
   intrinsic lowerings PLUS a new one for the seed (`bl` leaves the return
   address in `lr`, so an arm64 naked proc's SP points at no slot), two widened
   target sets and a restructured seed; or a loader-side walk seeded inside an
   intercept, which needs **nothing from arkham** and two small nifasm
   additions (force `ctx.traceUsed`; put the table's address on `MemImage`).
   The second is recommended for B4; arm64 `getStackTrace` is its own item.
5. **`nimony dev` watcher and restart diagnostics.** OS-specific, not
   CPU-specific; macOS is served by `lib/std/posix/kqueue.nim`, already here.
6. **a demo application, which has to be written.** `examples/` holds only
   one-shot tutorial scripts that run to completion, and JIT.md:638 already
   said the phase "needs a real demo application to be judged". Two hard
   constraints from the runtime: single-threaded (`image/memory.nim:27-38`
   refuses an image carrying a thread-local, and `std/rawthreads` has no
   `nimNoLibc` arm on macOS), and a long-lived loop with a reloadable body,
   since the gate is "survives a body edit without restart".

Gate: a demo application survives a body edit without restart and restarts
with a named reason on a signature edit.

## Phase B5 — Windows dev runtime, and linux/x86-64 qualification

Retitled: three of the four macOS/arm64 bullets this phase used to carry are
already built or were designed out, so what is left is Windows plus an x86-64
catch-up. Struck, with the evidence:

* ~~`MAP_JIT` + entitled helper~~ -- **not needed.** B0 measured on macOS 26 /
  M5 that plain RW→RX `mprotect` works for an unsigned, unentitled `nim c`
  binary, and `MAP_JIT`/`pthread_jit_write_protect_np` are deliberately NOT
  used because that dance is per-thread
  (`nativenif/src/nifasm/hostrun.nim:28-34`).
* ~~arm64 stub islands~~ -- **built**: `emitA64Stub`, a 12-byte ADRP+LDR+BR
  through a GOT slot (`.../src/nifasm/image/hostfixup.nim:79-98`), with the
  256 MB arena sized for `bl` reach (`hostrun.nim:17-26`).
* ~~`dlsym` for libSystem~~ -- **built**: the three-tier resolver (intercepts →
  arena → `dlsym(RTLD_DEFAULT)`), `.../src/nifasm/core/hostsyms.nim:62-67,
  123-145`.
* the **TLV thunk** moves to "later, optional": the in-memory path has no
  thread-locals by design and refuses an image carrying one
  (`.../src/nifasm/image/memory.nim:27-38`); `--dev-single-thread` is the
  sanctioned answer, and JIT.md 7.4 already lists "changed thread-local set" as
  a RESTART trigger rather than a reload case.

What remains:

1. **Windows dev runtime** -- `VirtualAlloc`/`VirtualProtect`/
   `FlushInstructionCache`, IAT patch via `pe.nim`, `TlsAlloc` thunk,
   `runImage` on Windows. Entirely unbuilt; `engine.hostIsSupported()` excludes
   Windows outright. JIT.md:644 still calls this the largest payoff (no MinGW;
   61 s vs 601 s bootstrap) and the least charted.
2. **linux/x86-64 qualification** -- arkham's x86-64 `&threadvar` lowering
   under `--dev-single-thread` (the `oneThread` arm `src/arkham/x64/` lacks),
   then the B0/B2 suites there, then flipping `engine.engineByDefault()`.
3. **`std/rawthreads`' `nimNoLibc` arm on macOS** -- not in the old text, but
   adjacent: it keeps the stdlib-wide corpus off the native backend here and it
   constrains what B4's demo application may import.

Gate: B3's numbers on each platform.

---

## Measuring

Every phase's own before/after numbers are necessary but not sufficient: the
number that matters is the merged branch against the fork point, on a quiet
machine, with one script. The rule, from 2026-09-06 on:

1. The fork-point toolchain lives in a worktree built once:
   `git worktree add /tmp/devloop_base f69b8afc && (cd /tmp/devloop_base &&
   nim c -r src/hastur/hastur build all)`.
2. After the agents of a wave have all reported and BEFORE the next wave is
   launched (the only window with no contention), run
   `bench/devloop_bench.sh /tmp/devloop_base base 3` and
   `bench/devloop_bench.sh . head 3`, and append both tables to
   `bench/results/<date>/progress.md` under the merged commit hash.
3. Read cpu-sum first, wall second, and peak resident size (the `rss` column, the largest process of the build) beside them: the design's low-memory goal is a gate too. A scenario whose cpu-sum is more than 5 %
   worse than `base` and is not explained by the phase that was just merged
   blocks the next launch until it is understood (profile with
   `nimony c -f --profile`, then bisect by phase branch).
4. The headline edit is `self.editbody` = a statement inserted into the body
   of `semStmt` in `sem.nim` (a live edit that reaches hexer, arkham, DCE and
   the link); `self.editdead` (a never-called proc appended) is kept because
   DCE deletes it and it measures only sem and hexer. Scenarios, all through the NATIVE backend (`nimony n`; `BACKEND=c` for the
   C path): the compiler compiling itself (`self.cold` / `nochange` /
   `editbody` / `edit` / `forced`) is the verdict; hello, CTFE `tmyops`,
   `bench/ctfe_bench.nim` and stdlib `tall.nim` (C backend until
   `std/rawthreads` has a nimNoLibc arm) are attribution. `hastur boot
   --boot-backend:native` is the correctness headline.

## Small items found by measuring (not phases)

- ~~`findTool("nimony")` resolves to a file named `nimony` in the current
  directory when one exists (a freshly built program called `nimony`), and
  the CTFE sub-compile then fails with `/bin/sh: nimony: command not found`.
  Pre-existing at the fork point. Fix: resolve tools next to the running
  executable only.~~ **done** (`jit/small-items`): `findTool` is `bin*/` and
  absolute names only -- no cwd, no bare name, no `PATH`; external programs
  (`cc`, `nim`, the system linker) resolve in `dag.resolveProgram`;
  `demandTool` names the directory searched. `incrementalToolShadowTests`.
- ~~The scheduler runs a depth's in-process nodes before its fan-out instead
  of alongside it (progress.md run 3b); worth ~0.1 s on a forced stdlib
  rebuild.~~ **done** (`jit/small-items`), and it is worth nothing on this
  tip: the relay is asked for the whole depth first (`decideOnly`), the
  spawned half starts, the accepted half runs on the main thread beside it
  (`dag.SpawnBatch` in place of `execProcesses`). Measured neutral because a
  depth is never MIXED -- every depth holds one phase, so an in-process depth
  has no spawned peer. Run 3b's 0.1 s is in-process time at `ready=1` depths;
  reaching it needs cross-depth pipelining, not this.
- ~~The no-change floor of a 127-module build is 0.11 s of dependency scan and
  graph emission (run 6).~~ **done** (`jit/small-items`): 74 -> 35 ms.
  `toPair` memoized in `DepContext` (32.9 ms of `getCurrentDir` +
  `relativePath`), `openLedger` deferred to the first question that needs it
  (9.6 ms), build files `OnlyIfChanged`. What remains is 20 ms of dependency
  scan and 13 ms of `runMake` parsing the two `.build.nif` files.
  `bench/results/2026-09-07/small-items.txt`.
- `std/rawthreads` has no `nimNoLibc` arm outside linux/x64 (B0); it keeps
  the stdlib-wide corpus off the native backend on macOS.
- nifasm's foreign-symbol lookup is the 0.07 s left in B3's incremental
  link (notes/b3.md): a symbol-table cache beside the fragments. Done (B3c).
- `--threads:off` for hexer, lengc, nifler and the nimony driver: -6 % on
  hexer over `sem.nim` (progress.md run 14); nimsem keeps threads for the
  engine's guest thread.
- hexer copies the module's `TokenBuf` once per pass (eleven passes;
  `memmove` + `skip` are ~35 % of its profile). Fewer copies per pass is the
  cache-shaped item; it is pipeline design, not a flag.

## Execution rules for agents

1. Work in a git worktree on a branch named `jit/<phase>`; commit there;
   report the branch, the worktree path, the test commands run and their
   verbatim tail output.
2. Build the toolchain in the worktree first (`nim c -r src/hastur/hastur
   build all`) and run the phase's test set plus `hastur test tests/nimony`
   before reporting.
3. Research first with cheaper agents: read the owner files, list every
   call site touched, confirm the plan's line references, and write the
   findings into the worktree as `notes/<phase>.md` before editing.
4. Never change golden files without listing the diff in the report.
5. No new global `var`s in phases A2a+; thread state through objects
   (AGENTS.md style rules apply: explicit state objects, no closures).
6. Do not touch `JIT.md`. Update the status line of the phase's section in
   `JIT_IMPL.md` when the phase is merged.
7. Never wait on a build, suite or benchmark with a shell polling loop
   (`until grep ...; do sleep N; done`): those were left behind as orphaned
   tasks. Run the command in the foreground with a timeout, or with
   `run_in_background` for one completion notification; use the Monitor tool
   only for per-event streams, with a filter covering every terminal state,
   and stop it when done. Leave no loop alive at the end of the task.

## Status

| phase | status | commit |
|---|---|---|
| P0a | merged (`-f` no longer forwarded; `runEval` memo with `.out.nif.reads` sidecar from `std/writenif`; `-d:vfsProfile` builds; `bench/ctfe_bench.nim` + `bench/ctfe_latency.sh`; tmyops forced 3.63 s -> 0.91 s, edit-rebuild 0.194 s -> 0.092 s; 793/793 tests, boot byte-identical) | merged from jit/p0a |
| P0b | merged (ocache under `nimcache/ocache/`; main module never owns a shared instantiation; second sub-program compiles 1 object instead of 8; `tmyops` user CPU 2.61 s -> 1.91 s) | merged from jit/p0b |
| P0c | merged (root cause: `.live.nif` serialized hash sets in pool-index order, so `OnlyIfChanged` never held; now sorted, one `<M>.live.nif` per module with its resolve subset, `<main>.all.live.nif` as the always-written anchor; sem.nim body edit: dceEmit 127 -> 1, self.editbody 2.83 -> 2.40 s wall, cpu 4.2 -> 2.4 s; 127 `.c.nif` byte-identical) | merged from jit/p0c |
| B0 | done (macOS/arm64 27/27 tiers; results in bench/results/2026-09-06/native_status.md) | |
| A1a | merged (`src/lib/ledger.nim`, `toolhash.nim`; fragments under `<dir>/.ledger/`, snapshot `<nimcache>/ledger.nif`; `--stats` per-phase table; overhead +0.78 %; nifmake spawn recording deferred to A1d) | merged from jit/a1a |
| A1b | merged (`src/lib/artifactstore.nim`; `--vfs:disk\|memory\|memory+spill\|verify`, `--vfs-budget`, policy handed to children via `NIMONY_VFS` env; 36 direct call sites converted; `nifmake.runNodeRelay` tri-state seam; whole tree green under `--vfs:memory+spill`; verify mode 0 mismatches) | merged from jit/a1b |
| A1c | merged (13 new consteval tests, `tests/ctfe_diff` harness; 4 CTFE bugs documented in `tests/nimony/consteval/todo/README.md`: enum/set results crash the serializer, distinct loses its conversion, `seq[UserObject]` unresolved, failed evaluations have no diagnostic) | merged from jit/a1c |
| A1d | merged (nifmake `SpawnLog` folded once per run into `<nimcache>/ledger.nif`; nimcache = dir of the build file; ledger-driven `maySpill` decision, exhaustively unit-tested; `--stats` spawn column + `[store]` line; overhead +0.5 %; fixed A1a's `recordSpawn` overwriting tool samples) | merged from jit/a1d |
| A2a-lengc | merged (`runLengc`, `resetLengcGlobals` (nothing to reset: audited), `generateCode` over `TokenBuf`/`MainModule`, `translate`/`serialize`/`writeGenerated` split, all five ledger buckets; `tests/inproc/lengc`) | merged from jit/a2a-lengc |
| A2a-hexer | merged (`runHexer`, `resetHexerGlobals` (prog, pool/fallbackPool, inliner stats), `expand`/`computeLiveSet`/`dceEmit` over buffers with `ExpandInput`/`ExpandResult`/`DceInputs`/`LiveSet`, `hexerio.nim`; `tests/inproc/hexer`; finding: `TypeCache` must be built before parse or SymIds shift) | merged from jit/a2a-hexer |
| A2a-front | merged (`runNifler`/`parseToBuf`/`writeParsed`; `runNimsem`/`semcheckToBuf`/`SemOutputs`/`writeOutputs`; `resetFrontendGlobals` = `resetPools` + `resetProgram` + identstyle + filelinecache resets; `tests/inproc/front`; finding: `semCompiles`'s save/restore is NOT sufficient for A2c, the snippet needs a fresh `SemContext` sharing `prog` and the pool; hexer's reset now calls the same procs) | merged from jit/a2a-front |
| A2b | merged; review: per-DEPTH decision with whole-node costs and fan-out = max(largest, serial/cores) + k*spawn, k = 1 (see progress.md run 3b); follow-up: overlap in-process nodes with the depth's fan-out (`src/nifmake/dag.nim` library + thin CLI; `src/nimony/phases.nim` registry for nimsem/hexer/dce*/lengc; rule: single-node depths in-process, wider depths compare `n*est` with `ceil(n/cores)*est + k*spawn` (review rewrite, A/B-measured); `--spawn:always\|auto`, `--jobs`, `--inproc-k`; nifler stays a process (three link blockers); `dag.nim` not nimony-compilable so a booted compiler spawns nifmake; hello no-change 14->6 ms, hello edit 82->65 ms; cold stdlib +0.5 % vs spawn-always) | merged from jit/a2b |
| A2c | merged (the CTFE sub-build runs in the parent's process: `FrontendSnapshot` moves `pool`/`globalTags`/`prog` aside and back; `.c.nif` cache for the stdlib closure, keyed after review on P0c's per-module `<M>.live.nif`; `writenif` precompile and macro-plugin builds in-process too; new evaluation 43 -> 27 ms; ctfe_diff compares the caller's `.s.nif` as well, 0 differences over 4 pairs; nimsem keeps spawning `nimony s` only when it is the process running sem, i.e. never under `nimony c`) | merged from jit/a2c |
| B1 (nativenif half) | done on `../nativenif` branch `jit/b1` (10 commits from pin d0781a48): `generateAsmBuf`, `AsmSession`/`emitRoots`, `AsmError`, `image/memory.nim` + `hostfixup.nim`, `core/hostsyms.nim`, `hostrun.nim` + `tools/nifrun`, `--dev-single-thread`; refactor gate byte-identical; 234/234 memory-vs-file code hash checks; CTFE sub-program runs from memory in ~8 ms with byte-identical `.out.nif` (reproduced by the integrator). Not yet: x64 `&threadvar` lowering (arkham side), Windows `runImage`, the nimony-side `nimony r`, re-pin of `src/nativenif.commit` | nativenif e368478 |
| B2 | merged (`src/nimony/engine.nim` behind `-d:nimonyEngine`, `--ctfe:subprocess\|engine` (default subprocess), `--ctfe-budget`, `NIMONY_CTFE_ENGINE=off`; `--ctfe-analysis-only` stops the sub-compile after `.c.nif`; `<nimcache>/asmcache/`; median 12 ms per new evaluation; 47/47 corpus evaluations through the engine, 0 fallbacks, 0 differences; pin `src/nativenif.commit` -> 3d20d5c (jit/b1 + path fix + `runImage` budget). The `bitabs` assertion was an out-of-bounds token read in nifasm's foreign-decl parser (fixed in nativenif 736b491, regression test, gate byte-identical; pin re-pointed). `--ctfe:auto` is now the default: the engine on macOS/arm64, the subprocess elsewhere until linux/x64 is exercised. Not done: per-proc code cache, `emitRoots` closure) | merged from jit/b2, jit/b2-fix |
| B1 (nimony half) | merged (`nimony r`: whole native graph minus the link node, `engine.runWholeProgram` assembles in-process and calls `main` from the arena; hello edit-to-run 0.320 -> 0.033 s; the compiler runs itself from memory; found nativenif's `_exit` intercept mis-keyed (`hostsyms.cName` strips on registration) -- worked around by registering `__exit`, fix belongs upstream; `bench/devloop_bench.sh` gained `hello.nrun/run`, `self.nrun/run` and an absolutised root) | merged from jit/b1-nimony |
| B3 (nativenif half) | done on `../nativenif` branch `jit/b3` (from pin 736b491): the cache unit is the SYMBOL and the cache file is the module, so the reachability worklist is untouched and the image is byte-identical to a scratch link; `--blobcache:DIR`, `--incremental`, `--blobcache-ro`, `--blobcache-hash`, `AsmSession.useBlobCache`/`saveBlobCache`, `core/asmprofile.nim` (`--profile`, `NIFASM_PROFILE=1`); 234/234 + 237/237 + 87/87 byte-identity checks over macho/elf/raw in four cache states. The 127-module compiler image: 841 ms from scratch, 928 ms cold, 335 ms warm. 0.07 s short of the ≤ 0.20 s gate, and the shortfall has one name — 212 ms of the warm link is `lookupWithAutoImport` following foreign names for the first time, i.e. a SYMBOL-TABLE cost, which is JIT.md 7.3's "`.x.nif` feed with the cached resolve step" and belongs to B4 | nativenif 713c819 |
| B3 (nimony half) | merged (`deps.blobCacheDir` = `<nimcache>/blobcache`, beside `ocache/`/`ccache/`; the native `link` node passes `--blobcache:<dir>` and `engine.runWholeProgram` calls `useBlobCache` on the same string, so both native paths share one store — one directory, two flag keys, because `nimony r` assembles `--dev-single-thread` without debug info and a linked executable does neither; `--no-blobcache` / `NIMONY_BLOBCACHE=off`, documented in `--help`; `--verbose`'s `[run-engine]` line gained `emitRoots=` and `blobcache=on hits=/stale=/recorded=`, `--profile` turns on nifasm's own per-stage table; pin `src/nativenif.commit` -> f8d2676. self.editbody 1.805 -> 1.381 s and self.run 1.785 -> 1.364 s (cache off vs on, same toolchain; 2.263 s at the fork point), compiler assemble 849.91 -> 484.11 ms after a `sem.nim` body edit (hits 3415, stale 18, recorded 627) and 245.10 ms with nothing edited. Byte identity checked three ways: `--no-blobcache` vs cached executables, `tests/nativecg`'s asm-NIF and exe, and `hastur boot --boot-backend:native` run in both states with stage 3 identical between them. Also upstreamed B1's `_exit` workaround as a real fix and dropped it here. What is left of a warm link is 318 ms of `blobResolve`+`blobRefs`, a symbol-table cost that is B4's) | merged from jit/b3-nimony, nativenif jit/b3-fixes f8d2676 |
| B3b | measured, NOT built (`notes/b3b.md`): sem's output is not declaration-stable (module-wide local numbering, line info) and arkham's labels are module-scoped, so the ≤ 0.2 s gate is unreachable from hexer/arkham alone; a `decl-stability` scenario pins the ratios; prerequisites are frontend changes (owner decision) -- symbol-granularity lowering — hexer and arkham re-lower only the procs whose Leng changed, so a body edit in a 7k-line module costs one proc; pulled forward from B4 because the compiler's edit loop after B3 is ~0.45 s nimsem + 0.36 s hexer + 0.41 s arkham on ONE module (progress.md run 6) | |
| B3c | merged (nativenif `jit/b3c`, pin c3f27fc: `core/declhead.nim` reads a foreign proc's signature without its body; warm compiler link 0.27 -> 0.086 s, `sem.nim`-edited 0.43 -> 0.28 s; byte-identical; headline 2.78 -> 1.26 s wall) | nativenif c3f27fc |
| small items | merged (`findTool` never resolves via cwd/PATH, `dag.resolveProgram` for external programs; in-process nodes overlap the fan-out (measured neutral: depths are homogeneous); no-change floor 74 -> 35 ms) | merged from jit/small-items |
| F1 | merged (locals `` x.N`routine`0 ``: one dot, so every `symparser` scanner still classifies them local; module-wide uniqueness kept for `hexer_context.hoistedConsts`; `src/hexer/decldigest.nim` + `<mod>.decls.nif` line-info-blind digests and `rebaseLineInfo`; appended proc changes 1/0 declarations instead of 465/464; `self.editbody` 2.71 -> 0.77 s; artifacts +31 % bytes, cold +3 % cpu; 21 goldens renamed. Follow-ups: diagnostics should print the base identifier, not the namespaced spelling; `derefs`/`controlflow` counters) | merged from jit/f1 |
| B3b (2nd attempt, after F1) | measured, NOT built again (`notes/b3b.md` §10-15, `bench/results/2026-09-07/b3b.txt`): on this tip `self.editbody` costs arkham 0.000 s and link 0.000 s — its appended proc is private and dead, so `dce` deletes it and the backend graph is up to date — so the gate reads "hexer ≤ 0.1 s from 0.27 s", and hexer's floor is 112 ms with zero declarations lowered. The splice is also unsound: F1's sidecar reports 1 changed sem-input declaration and **890 of 1794 changed lowering-output** declarations for an edit that mints one extra temp (`Pass.nextTemp`, `InlinerCtx.counter`), and an edit to the LAST declaration renumbers the FIRST — so §2's "prefix theorem" is false for the pipeline. arkham's own drift is 28 of 1949 (F1 removed the rest); nifasm reports stale 18, not 540, but records 627 fragments where 467 changed. New prerequisite, ahead of all three steps: scope hexer's counters per declaration, F1's move one level down. Landed: `passes.StageTimer` (the 14-stage breakdown of `expand`, byte-neutral over 381 artifacts) and a fourth `decl-stability` phase asserting the lowering-output digest, which nothing had ever checked | jit/b3b |
| M1 | merged (`LedgerSample.rssBytes` from `getrusage` at `PhaseTimer.finish`, spawned samples preferred over driver peaks; `--stats` `peak MB` column + driver/largest-child line; scheduler declines in-process work when `driverPeak + max(node rss) > budget`, budget `clamp(physmem/(32*cores), 128 MB, 1 GB)`, `--inproc-mem-budget`; cold self-compilation largest process 218 -> 147 MB at no wall cost; the 147 vs 116 is `dceLive` 84 -> 147 MB from P0c's per-module resolve subsets -- streaming them out is the follow-up) | merged from jit/m1 |
| F1 follow-ups | merged (diagnostics render `symparser.sourceIdent` + location, 18 call sites, 10 `.msgs` goldens; `derefs` `err` and `controlflow` `cf` counters per declaration; five older `makeGlobalSym` leaks into messages fixed; a pre-existing C-backend bug noted: a value-returning proc that catches a ref exception fails codegen) | merged from jit/f1-followups |
| F2 | merged (`passes.TempNamer`: every synthesized symbol in hexer named per top-level declaration in F1's spelling -- xelim, inliner, desugar, lambdalifting, coro, duplifier, vtables, iterinliner, stringcases, lengcgen; module-lifetime tables keep uniqueness through the namespace; live `sem.nim` edit changes 3 of 1785 lowering-output declarations (was 890); `tempadd` bound is `== 1`; `.x.nif` +28 % bytes; nifasm still records 627 (per-module validity) -- B3d) | merged from jit/f2 |
| B3d | merged (nativenif 7b838ec: `core/asmdecls.nim` digests a module per declaration from its embedded index -- asm-NIF carries no line info -- and a fragment depends on its own declaration's digest plus every declaration it named; blobs hold two module versions until `flush` prunes; arkham names labels and constructor temps per proc: 434 -> 3 changed asm declarations on the live edit; link 0.32 -> 0.12 s, blob recorded 627 -> 18; live edit 2.65 -> 1.08 s; refactor gate: nifasm commit identical, arkham commit 137 renamed artifacts, no image hash moved) | merged from jit/b3d |
| B3e | merged (pin nativenif 5f6f011) -- done on `jit/b3e` + nativenif `jit/b3e-native` (`notes/b3e.md`): `--asmcache:DIR` writes a `<mod>.arkham.nif` sidecar holding each proc's line-info-blind `.c.nif` digest and the BYTE RANGE its text occupies in the `.asm.nif` beside it -- no generated byte is stored, the text is copied out of the module's own previous output whose content hash the sidecar records, so the two cannot disagree. A spliced proc is a `(arkhamsplice n)` marker in the token buffer (a remembered position does not survive `finish`'s peephole) and replays what it owed the module (`rodata`, whose names are minted from the running count, and the two firmware divider flags). The key: arkham's build id + target + every non-proc declaration + every proc SIGNATURE + the ANSWERS of `cleanSigProcNames`/`noReturnProcs` (the latter walks every body, so a body edit can change another proc's frame); hexer's `(smry ...)` is excluded -- it is computed from the proc's own body and made every signature a function of it (0 of 526 spliced until that was found). Cross-module: the file stamp is asked first, and a stamp that MOVED asks about the declarations this lowering actually read out of that module, per PROC -- `notes/b3d.md` §3.3's per-reference rule one tool earlier. Live edit: 523 of 526, 76 of 78 and 8 of 9 procs spliced, arkham 0.259 -> 0.089 s, `sem.nim` alone 196 -> 63 ms; cold -2 %; headline 2.61 -> 0.92 s. Byte-identical: 651 splice self-test checks over five corpus/target pairs in eight states, 0 of 127 compiler modules differ cached vs not (also with the cache populated before the edit: 4045 procs spliced, 0 differ), the linked compiler identical, refactor gate identical to `7b838ec`, boot 1 == 2 == 3 | nativenif 5f6f011 |
| H1 | NOT built as scoped -- the premise was a measurement artifact (`notes/h1.md`, `bench/results/2026-09-07/h1.txt`): `dceLive`'s 0.36 s was not the whole-program recomputation but an accidental deep copy. `markLive` took `moduleGraphs` non-`var`, so every lookup bound `compat2`'s BY-VALUE `getOrQuit` and `let graph = moduleGraphs.getOrQuit(moduleName)` copied a whole `ModuleAnalysis` (a `Table[SymId, HashSet[SymId]]` plus two `HashSet`s) on each of the 7867 worklist pops, plus the dependency set on top. Reading the 131 `.dce.nif` is 19 ms and the fixpoint is 7 ms; the other 305 ms was copying. Taking the table as `var` and never materializing the intermediate: `hexer dl` 0.36 -> 0.05 s, in-build `dceLive` 0.367 -> 0.062 s (gate <= 0.08), first-rebuild-after-an-edit wall 1.39 -> 1.10 s, cold 5.08 -> 4.79 s, all 131 `<M>.live.nif` + anchor byte-identical. No incremental live set built: at 51 ms against an 80 ms gate it could remove ~11 ms for a persisted graph, a delta classifier, a fallback rule and a byte-identity obligation on every live-set-SHRINKING edit (which needs the previous analysis, because minimality can only be rechecked by re-running the fixpoint). Also found: `devloop_ab.sh self.editbody`'s 5-round MEDIAN cannot measure `dceLive` -- its edit leaves `.dce.nif` byte-identical after round 0, so 4 of 5 rounds skip the node | merged from jit/h1 |
| upstream merge chain | merged (`MERGE.md`): the six commits master gained after the fork point, one branch per commit, plus the F1 respelling (`643569c2`) that `e1da48e9` requires and the nativenif re-pins `3ec73fef` and `9d7fcf78`. 795/795, boot 1 == 2 == 3, ctfe_diff 0, decl-stability 1/0/1/1. **Costs the edit loop 13.8 % cpu** (`self.editbody`, pre-chain `6870790c` against post-chain `95fff89d` interleaved in one run; editcall 1.147, editdead 1.156, cold 1.072, no-change 1.000, peak RSS unmoved). Decomposed commit by commit into five interleaved runs whose product is 1.137 against the 1.138 measured end to end: **`c6be04e1` "no globals in nifcore" 1.057** and **`e1da48e9` "nifsyms refactor" (with its pin) 1.066** are the whole of it, both putting an indirection on the pipeline's hottest read; steps 1-3 together 0.998, step 5 1.005, and OUR F1 respelling **1.006**, i.e. nothing in the number is ours. Tested and rejected as a fix: memoizing `decldigest`'s per-token spelling (1.074 -> 1.070, digests bit-identical). The headline against the fork point is therefore 2.58 -> 1.02 s wall on the live edit (was 2.30 -> 0.92 before the chain) | run 19/20, `bench/results/2026-09-07/postchain.txt` |
| B4 | stage 1 done (`notes/b4.md`), stages 2-6 planned. **1a** (the design question the staging existed to catch): the trace-table walk is the SAME mechanism as `lib/std/stacktraces.nim` -- a synchronous walk of the guest's own stack, because `cfaOff` is valid only past the prologue (`tracetable.nim:36-39`) and an out-of-process guest cannot be reached across the boundary without the entitlement B0's design refuses (`hostrun.nim:28-34`). Not a different phase; and the arm64 gap is SMALLER than estimated if the walk is loader-side (nothing from arkham), LARGER by one intrinsic if it is guest-side (`bl` leaves the return address in `lr`, so an arm64 naked proc's SP points at no slot). **1b**: `src/nimony/guestwire.nim` (socketpair on fd 3, length-framed records, `posix_spawn`, signal re-raise), `src/nimony/nimrun.nim` (the loader -- it calls `engine.runWholeProgram`, so out-of-process is not a second implementation), `engine.runWholeProgramOutOfProcess`, `nimony r --guest:inproc\|subprocess` (default `inproc`), `hastur build all` builds `nimrun`. Gate met: `tests/inproc/guest` runs two different programs from ONE host process, byte-identical stdout and exit status against two `nimony r` invocations, host thread count unchanged. 50 runs from one process: in-process 51 threads / +13.6 GB / 0.52 s, out-of-process 1 thread / 0 / 0.15 s | jit/b4 |
| B5 | planned (retitled: Windows + linux/x86-64; three macOS/arm64 bullets struck as built or designed out) | |
