# Phase A1a — research notes

Written before editing, per `JIT_IMPL.md` "Execution rules for agents" rule 3.
Line numbers are from `fast-devloop` at `4fdfdbf4` (P0a, P0b and A1c merged).

## 1. Where each tool does its work

The four tools reach their phase through one call in their own driver file,
which is the only file A1a is allowed to touch per tool.

| tool | entry point | phase proc | where the output goes |
|---|---|---|---|
| nifler | `nifler.nim:39 handleCmdLine` | `bridge.parseFile` (`bridge.nim:922`), called at `nifler.nim:80` | `nifbuilder.Builder` opened on `outp` inside `initTranslationContext` (`bridge.nim:888`), flushed by `tc.close` |
| nimsem | `nimsem.nim:100 handleCmdLine` -> `processModules` (`nimsem.nim:60`) | `semmain.semcheck` (`semmain.nim:711`), called at `nimsem.nim:72` | `semmain.writeOutput` (`semmain.nim:137`) -> `nifpools.writeFile` -> `vfsWrite` |
| hexer | `hexer.nim:77 handleCmdLine` | `lengcgen.expand` (`lengcgen.nim:2798`), `dce2.computeLiveSet` (`dce2.nim:318`), `dce2.dceEmit` (`dce2.nim:335`) | `writeFile outputBuf, destfileName` (`lengcgen.nim:2869`), `writeLiveFile` (`dce2.nim:237`), `rewriteModule` (`dce2.nim:194`) |
| lengc | `lengc.nim:80 handleCmdLine` -> `generateBackend` (`lengc.nim:55`) | `codegen.generateCode` (`codegen.nim:837`) | `vfsWrite outp, f.buf` (`codegen.nim:880`) |

Load, phase, serialize and write are **not** separable from the driver files:
each of the four phase procs opens its own input (`programs.setupProgram`,
`nifmodules.load`, `llStreamOpen`) and writes its own output from inside.
Splitting them needs the buffer-level entry points of phase A2a, and the
intermediate files (`semmain.nim`, `lengcgen.nim`, `dce2.nim`, `codegen.nim`,
`bridge.nim`) are where A1b converts direct OS calls into `vfs*` relays, so
A1a must not edit them. **A1a therefore records the whole phase call as
`produce` and the size of the phase's output as `bytes`;** `serialize`,
`write`, `load` and `parse` stay 0 until A2a exposes the seams. The
`PhaseTimer` API carries all six buckets already so that A2a only has to add
`note*` calls.

## 2. Where the module suffix and the artifact directory come from

- nifler: neither exists. The output path is all it has; the suffix is the
  basename of `outp` up to its first dot.
- nimsem: `config.nifcachePath` (`nifconfig.nim:106`) is in scope in
  `handleCmdLine`, and `processModules` computes `outfiles` itself. The suffix
  is `SemContext.thisModuleSuffix`, which does not reach `nimsem.nim`; the
  same string is the basename of the outfile.
- hexer: `--outdir` (`hexer.nim:82`), else the input file's own directory —
  which is what `lengcgen.expand` itself does (`EContext.dir`,
  `lengcgen.nim:2800`). Suffix: `splitModulePath(files[0]).name`.
- lengc: `s.config.nifcacheDir` (`noptions.nim:32`), set from `--nimcache`
  (`lengc.nim:167`). `generateBackend` already computes
  `splitModulePath(inp).name`.

The important consequence: **`--nimcache` does not mean the same directory in
every tool.** `deps.nim:1776` hands lengc `--nimcache:<backendDir>` and
`deps.nim:2226` hands the main module's hexer `--outdir:<backendDir>`, where
`backendDir = nifcachePath / backendDirName(main)` (`deps.nim:1468`,
`deps.nim:77`). So the backend phases genuinely write one directory below the
nimcache. See deviation 2 below.

## 3. Reading and writing a small NIF sidecar

- Writing: `nifbuilder.Builder` (`src/lib/nifbuilder.nim`). `open(filename)`
  buffers in memory and flushes through `vfsWrite` at `close()`;
  `addHeader(vendor, dialect)`, `withTree`, `addStrLit`, `addIntLit`,
  `addIdent`. `dce1.nim:87` and `dce2.nim:246` are the precedent — both are
  hexer modules, i.e. they are compiled by nimony during `hastur boot`, which
  proves the API is available in both dialects.
- `nifpools.writeFile` (the `TokenBuf` path `semmain.writeNewDepsFile` uses)
  needs the global pool and registered `TagId`s; for a standalone sidecar
  `Builder` is the lighter and the more portable of the two.
- Reading: `nifreader.openFromBuffer(content, "")` plus `next(r, tok)` walks
  the token stream with no pool to intern into. `nifreader.open` *quits* on a
  missing file (`nifreader.nim:569`), so a missing ledger is guarded with
  `vfsExists` and read with `vfsRead`.
- `vfsWrite` is already atomic (`vfs.nim:134-171`: write a
  `atomicTempPath` sibling, then `vfsMoveInto`). No extra atomicity is needed
  for the fragments.
- Monotonic clock: `getMonoTime().ticks` is `int64` nanoseconds and `ticks*`
  is exported by both `std/monotimes` (host) and `lib/std/monotimes.nim:139`
  (nimony), so no `Duration`/float detour is needed.
- Hashing: `nifchecksums.computeChecksum(s: string)` is the repo pattern, but
  it drags `nifpools` (the global pool) in. `toolhash.nim` uses `std/sha1`
  directly with the same `{.push warning[Deprecated]: off.}` guard, so nifler
  does not gain a pool it never used.

## 4. `hastur` custom runners

`walk.collectTests` (`walk.nim:96`) treats a directory holding `setup.nim` as
a leaf: it does not recurse and does not look at the other `.nim` files there,
so `tests/ledger/hello.nim` is a fixture, not a test. `runSetupNimDir`
(`walk.nim:37`) compiles the runner with `nim c -r` and passes `--dir`,
`--bindir`, `--cachedir`, plus `--overwrite`/`--forward` when given; the
runner's **exit code is the whole verdict**. `tests/incremental/setup.nim`
imports `src/hastur/kit`; the ledger runner needs only `toolchainDir` and
`nimcacheDir`, so it imports `src/hastur/context` and keeps its compile short.

## 5. Both dialects

`hastur boot` self-compiles `nimsem`, `hexer` and `nimony` with nimony
(`boot.nim:24`), so `src/lib/ledger.nim` and `src/lib/toolhash.nim` are
compiled by **nimony** as well as by Nim. That shapes the implementation:

- `std/tables` with a custom key would need a `hash` overload; a short sorted
  `seq` avoids the question entirely and the table has tens of entries.
- `swap` does not exist in nimony's `system`, and nimony rejects
  `s[i] = s[i-1]` on the same mutable seq ("mutable argument aliases with
  immutable parameter"). The insertion shift copies through a local.
- `walkDir`, `createDir`, `getFileSize` and `getLastModificationTime` have
  different shapes in the two dialects; they are wrapped once, in the same
  `when defined(nimony)` style `vfs.nim` uses.
- Floats are avoided end to end (integer EWMA, integer millisecond
  formatting), which also makes the NIF round trip exact.

## 6. Deviations from the interface block in `JIT_IMPL.md`

1. **Durations are stored as `ns` integers, not `ms` floats.** JIT.md 5.2
   sketches `(produce ms 13.2)` and `(updated "2026-09-06T11:48Z")`; the
   normative interface block in `JIT_IMPL.md` stores `produceNs*: int64` and
   `updated*: int64  # unix ns`. The average is re-read and re-averaged on
   every build, so a decimal formatter in the loop would let it drift. The
   tree shape is otherwise the one from JIT.md, with the unit spelled out:
   `(produce ns 13200000)`. `bytes` is a sibling of the duration trees rather
   than a field of `serialize`, because it belongs to the sample, not to the
   serialization step.
2. **The fragment directory is `<dir>/.ledger/`, not `<dir>/ledger/`**, and
   `openLedger` folds `<nimcache>/.ledger/` *and* `<nimcache>/*/.ledger/`.
   - The subdirectory scan is forced by section 2: lengc and the main
     module's hexer write into `<nimcache>/<main>_c/`. Reconstructing the
     nimcache from that would mean guessing at directory names; scanning one
     level down does not, and it needs no new command-line flag (adding one
     would mean editing `deps.nim`'s command emission, which A1a does not
     own).
   - The dot prefix is not cosmetic: `<nimcache>/<main>_c/` is also where the
     linker puts the executable, so a plain `ledger` directory makes
     `nimony c ledger.nim` fail with `ld: open() failed, errno=21 (Is a
     directory)`. Verified before the rename. A name that cannot be a module
     name cannot collide.
3. **`LedgerEntry` carries its `key`, and `Ledger` is a sorted `seq`** rather
   than a `Table`. Both are internal shape, not signature: `openLedger`,
   `record`, `estimate`, `saveLedger` and `toolhash` keep the names and
   parameter lists from the plan.
4. **`estimate` gained an overload taking the toolhash explicitly.** The
   no-argument form filters on `toolhash()` exactly as specified. But every
   tool has its own executable and therefore its own toolhash, so a `nimony`
   process asking for a `lengc` estimate would filter everything out; A1d and
   A2b need the door. `--stats` reports the raw entries and does not go
   through `estimate` at all.
5. **Additions for A1d** (`JIT_IMPL.md` A1a step 3, which is nifmake's half of
   the work and is deferred): `recordSpawn(dir, key, spawnNs, toolhash)`
   attaches a spawn cost to a key another process measured without inflating
   its sample count, `consolidate(nimcache)` folds every fragment into
   `<nimcache>/ledger.nif`, and `openFragment`/`fragmentPath` expose one key's
   history. `nifmake.nim` is untouched.
6. **`produce` is the whole phase call** (section 1). `serialize`, `write`,
   `load` and `parse` are recorded as 0 by the four tools in this phase.

## 7. Fragments are never deleted

`ledger.nif` is a *snapshot*: `saveLedger` writes the folded table and leaves
the fragments alone. The fragment, not the snapshot, is what accumulates a
key's history — `writeFragment` reads its own fragment back before recording,
which is what makes `samples` and the average survive a run. Deleting
fragments after a merge would restart every average at one sample on the next
build, so `consolidate` does not.
