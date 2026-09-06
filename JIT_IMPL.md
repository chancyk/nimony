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

## Phase B4 — hot reload and `nimony dev`

Layout sidecar and classifier, slot swap with generation counter,
trace-table stack walk (x64 first), watcher, restart diagnostics.

Gate: a demo application survives a body edit without restart and restarts
with a named reason on a signature edit.

## Phase B5 — macOS/arm64 and Windows dev runtime

`MAP_JIT` + entitled helper, TLV thunk, arm64 stub islands, `dlsym`;
Windows `VirtualAlloc`, IAT patch via `pe.nim`, `TlsAlloc` thunk.

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
3. Read cpu-sum first, wall second. A scenario whose cpu-sum is more than 5 %
   worse than `base` and is not explained by the phase that was just merged
   blocks the next launch until it is understood (profile with
   `nimony c -f --profile`, then bisect by phase branch).
4. Scenarios: hello (forced / no change / edit), CTFE `tmyops` (cold / warm /
   edit / forced), `bench/ctfe_bench.nim` (cold / edit), stdlib `tall.nim`
   (cold / forced / `strutils` edit). B-track phases add `nimony r` and the
   engine's per-evaluation time when those exist.

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

## Status

| phase | status | commit |
|---|---|---|
| P0a | merged (`-f` no longer forwarded; `runEval` memo with `.out.nif.reads` sidecar from `std/writenif`; `-d:vfsProfile` builds; `bench/ctfe_bench.nim` + `bench/ctfe_latency.sh`; tmyops forced 3.63 s -> 0.91 s, edit-rebuild 0.194 s -> 0.092 s; 793/793 tests, boot byte-identical) | merged from jit/p0a |
| P0b | merged (ocache under `nimcache/ocache/`; main module never owns a shared instantiation; second sub-program compiles 1 object instead of 8; `tmyops` user CPU 2.61 s -> 1.91 s) | merged from jit/p0b |
| B0 | done (macOS/arm64 27/27 tiers; results in bench/results/2026-09-06/native_status.md) | |
| A1a | merged (`src/lib/ledger.nim`, `toolhash.nim`; fragments under `<dir>/.ledger/`, snapshot `<nimcache>/ledger.nif`; `--stats` per-phase table; overhead +0.78 %; nifmake spawn recording deferred to A1d) | merged from jit/a1a |
| A1b | merged (`src/lib/artifactstore.nim`; `--vfs:disk\|memory\|memory+spill\|verify`, `--vfs-budget`, policy handed to children via `NIMONY_VFS` env; 36 direct call sites converted; `nifmake.runNodeRelay` tri-state seam; whole tree green under `--vfs:memory+spill`; verify mode 0 mismatches) | merged from jit/a1b |
| A1c | merged (13 new consteval tests, `tests/ctfe_diff` harness; 4 CTFE bugs documented in `tests/nimony/consteval/todo/README.md`: enum/set results crash the serializer, distinct loses its conversion, `seq[UserObject]` unresolved, failed evaluations have no diagnostic) | merged from jit/a1c |
| A1d | planned | |
| A2a-lengc | merged (`runLengc`, `resetLengcGlobals` (nothing to reset: audited), `generateCode` over `TokenBuf`/`MainModule`, `translate`/`serialize`/`writeGenerated` split, all five ledger buckets; `tests/inproc/lengc`) | merged from jit/a2a-lengc |
| A2a-hexer | merged (`runHexer`, `resetHexerGlobals` (prog, pool/fallbackPool, inliner stats), `expand`/`computeLiveSet`/`dceEmit` over buffers with `ExpandInput`/`ExpandResult`/`DceInputs`/`LiveSet`, `hexerio.nim`; `tests/inproc/hexer`; finding: `TypeCache` must be built before parse or SymIds shift) | merged from jit/a2a-hexer |
| A2a-front | running | |
| A2b | planned | |
| A2c | planned | |
| B1 (nativenif half) | done on `../nativenif` branch `jit/b1` (10 commits from pin d0781a48): `generateAsmBuf`, `AsmSession`/`emitRoots`, `AsmError`, `image/memory.nim` + `hostfixup.nim`, `core/hostsyms.nim`, `hostrun.nim` + `tools/nifrun`, `--dev-single-thread`; refactor gate byte-identical; 234/234 memory-vs-file code hash checks; CTFE sub-program runs from memory in ~8 ms with byte-identical `.out.nif` (reproduced by the integrator). Not yet: x64 `&threadvar` lowering (arkham side), Windows `runImage`, the nimony-side `nimony r`, re-pin of `src/nativenif.commit` | nativenif e368478 |
| B2–B5 | planned | |
