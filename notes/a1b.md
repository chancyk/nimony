# Phase A1b — research notes

Written before the implementation, per `JIT_IMPL.md` "Execution rules for
agents" rule 3. Worktree branch `jit/a1b`, forked from `fast-devloop`
(`4fdfdbf4`, i.e. with P0a, P0b and A1c already in).

## 1. The relay layer as it stands

`src/lib/vfs.nim` (319 lines). Seven relay variables, all `{.nimcall.}` proc
`var`s with an OS-backed default, and seven portable wrappers over them:

| relay | wrapper | default |
|---|---|---|
| `openMmapRelay(path): VfsBlob` | `vfsOpenMmap` | `memfiles.open` wrapped by `fromMemFile` |
| `readBytesRelay(path): string` | `vfsRead` | `readFile` |
| `writeBytesRelay(path, content)` | `vfsWrite` | temp + `vfsMoveInto` |
| `existsRelay(path): bool` | `vfsExists` | `fileExists` |
| `mtimeRelay(path): int64` | `vfsMtime` | `getLastModificationTime`, ns since epoch |
| `nowRelay(): int64` | `vfsNow` | `getTime`, same space |
| `removeRelay(path)` | `vfsRemove` | `removeFile` |

Not relayed, and deliberately so: `vfsMoveInto` (single-syscall publish),
`vfsRemoveTree`, `atomicTempPath`.

`VfsBlob` is `{data, size, mf, cookie, cleanup}`. The backend owns the
lifetime through `cookie` + `cleanup`; `closeBlob` is idempotent. The
invariant the store has to carry over is the one PR #2396 established
(`0b2031d5`, "nif: replace cache files atomically, never truncate a mapped
one"), stated in `vfs.nim` as *"Never truncate a `.nif` or `.bif` that a
reader may have mmap'd"*: `vfsWrite` writes a `.tmp.<pid>.<n>` sibling and
renames it over the target, so a reader that mapped the old inode is
undisturbed. In memory that becomes **replace the entry, never mutate it**.

Indirect adoption already covers a lot: `nifreader.open`, `nifbuilder.open`/
`close`, `nifpools.writeFile`, `nifindexes.writeFileAndIndex`, `bif.store`/
`bif.load` are all built on the relays, so every `.nif` read/write that goes
through those helpers is already routed. What is left is the *staleness
checks and the hand-rolled reads/writes* around them.

## 2. Direct OS file calls that touch build artifacts (the conversion list)

Everything below bypasses the relays today and names a file that is a product
of the build. This is the list Phase A1b converts.

| file:line (fork point) | expression | artifact | note |
|---|---|---|---|
| `src/nimony/semos.nim:339-341` | `fileExists(src)`, `getLastModificationTime(src)`, `getLastModificationTime(depsFile)` | `.p.nif`, `.p.deps.nif` | `needsUpdate` staleness |
| `src/nimony/semos.nim:494,498` | `fileExists(file)`, `readFile(file)`, `writeFile(file, content)` | plugin `.in.nif`/`.types.nif` input | `writeFileIfChanged` |
| `src/nimony/semos.nim:730` | `fileExists(dir / "…s.nif")` | `std/writenif`'s `.s.nif` | `prepareEval` precompile check |
| `src/nimony/semos.nim:768` | `writeFile(depsFile, …)` | `<sfx>.p.deps.nif` | CTFE sub-program deps |
| `src/nimony/programs.nim:229,234` | `fileExists(output)`, `getLastModificationTime` ×2 | `.s.nif`, plugin exe | `needsRecompile` |
| `src/nimony/macro_plugin.nim:302,354` | `writeFile(depsFile, …)`, `writeFile(inputPath, …)` | `.p.deps.nif`, `macro_in_*.nif` | |
| `src/nimony/deps.nim:710-712` | `fileExists(output)`, `getLastModTime` ×3 | `.p.nif`, `.deps.nif` | `execNifler` staleness |
| `src/nimony/deps.nim:746` | `fileExists(depsFile)` | `.deps.nif` | `loadDepsFile` |
| `src/nimony/deps.nim:1194` | `readFile(p)` | `.c.nif` | ocache key digest |
| `src/nimony/deps.nim:2046-2051` | `fileExists`, `readFile`, `writeFile` | `<main>.cached.config` memo | drives `--rerun` |
| `src/hexer/intramodinliner.nim:352,354` | `fileExists(direct)`, `fileExists(parent)` | foreign `.c.nif`/`.x.nif` | pre-check before a vfs read |
| `src/lengc/nifmodules.nim:163` | `fileExists($c.prog.scheme)` | foreign module file | same shape |
| `src/lengc/shoggoth/optdriver.nim:238,251` | `readFile(input)`, `writeFile(output, …)` | `.c.nif` -> `.oc.nif` | |
| `src/nifler/nifler.nim:75-77,87` | `fileExists` ×3, `getLastModificationTime` ×4 | `.nif`, `.deps.nif`, `.cfg.nif` | nifler's own staleness |
| `src/nifler/configcmd.nim:219` | `getLastModificationTime(configFile)` | `.cfg.nif` | `sourcesChanged` |
| `src/nifmake/nifmake.nim:537` | `writeFile(filename, content)` | generated `Makefile` | see below — NOT converted |

Counts: ~70 direct OS file-call expressions across the five directories, of
which the ~30 expressions above (in 15 files) name build artifacts.

### Intentionally left alone

The rest are not file *content* operations on build products, and the header
comment of `artifactstore.nim` carries this list:

- directories: `createDir` (`semos.nim:367,369`, `deps.nim:2318-2373`,
  `lengc.nim:24,26`, `shoggoth.nim:64`), `dirExists`, `removeDir`/`walkDir`
  (`patextract.nim:159-162`).
- executables: `semos.nim:106,429`, `deps.nim:984`, `macro_plugin.nim:347`,
  `patextract.nim:46`. `vfsMoveInto` already owns publishing one.
- user source files and data: `expreval.nim:339` (`slurp`), `semos.nim:137,302`,
  `deps.nim:190,314,336,356,373,573,2391,2393`, `semimport.nim:80,173`,
  `sempragmas.nim:951,982,1007`, `semdata.nim:311`, `plugins.nim:99`,
  `configcmd.nim:21,23,227,229`.
- debug-only output: `semmain.nim:474-527` (`-d:dumpPhases`),
  `controlflow.nim:1227` (its own `isMainModule` driver), `passes.nim:43`
  (`$NIMONY_PASS_TIMING` append log).
- `nifmake.nim:537` `generateMakefile`: an export utility, not a node output.
- process execution: `execShellCmd`/`execCmdEx`/`execProcesses` (~14 sites).

## 3. What crosses a process boundary

Every artifact does, today. Verified per suffix:

| suffix | written by | read by (a different process) |
|---|---|---|
| `.p.nif`, `.p.deps.nif` | nifler (and `runEval` for the CTFE snippet) | nimsem, the nimony driver |
| `.cfg.nif` | nifler `config` | nimony driver |
| `.s.nif`, `.s.idx.nif` | nimsem | the importer's nimsem, hexer, lengc/arkham via `foreignmodules` |
| `.s.deps.nif` | nimsem | nimony driver; the *outer* nimsem for the CTFE memo |
| `.x.nif`, `.dce.nif` | hexer `c` | hexer `dl`, hexer `de`, `intramodinliner` |
| `.live.nif` | hexer `dl` | hexer `de` |
| `.c.nif` | hexer `de` | lengc, shoggoth |
| `.oc.nif` | shoggoth | lengc |
| `.c`, `.o` | lengc, cc | cc, link |
| `.out.nif` | the CTFE sub-program binary; a plugin exe | nimsem |
| `.out.nif.reads` | `std/writenif.teardown` in the sub-program (P0a) | nimsem's `evalMemoIsFresh` |
| `ocache/<hash>.{c,o}` | `deps.publishObjectCache` (P0b) | a *later* sub-compile's driver |
| `*.build.nif` | nimony driver | nifmake |
| everything above | — | nifmake, for mtimes |

So the write-through set is "all of it", and a per-process store is a read
cache plus a write coalescer until A2b/A2c put phases in one process. That is
what `JIT_IMPL.md` predicts ("a store per process is only useful once phases
share a process") and it is why the phase's gate is byte-identity rather than
a speedup.

Consequence for correctness: because everything is written through, a child
process can legitimately rewrite a path the parent has resident. The store
therefore records the disk mtime it wrote and revalidates against it before
answering from memory — one `stat`, the same syscall the caller was going to
make for `vfsExists`/`vfsMtime` anyway.

## 4. nifmake

`runDag` (`nifmake.nim:373-486`) has two paths. Both compute
`expandCommand(...)` into a single shell string. Sequential calls
`executeCommand` (`execShellCmd`); parallel collects the strings of one DAG
depth and hands them to `osproc.execProcesses` with `beforeRunEvent`/
`afterRunEvent`. Staleness is `needsRebuild` (`:220-250`), which is already
`vfsExists`/`vfsMtime` only. `removeOutdatedArtifacts` (`:208-218`) is
`--force` only and already relayed.

The A2b seam therefore has to be per *node*, before the batch is assembled,
and it has to be able to say "I ran it" as well as "spawn it": a tri-state,
not a `bool`. `--report` counts and `--profile` timings are per command name
and must stay identical when the relay always answers "spawn".

`--report` format (`printReport`, `:694-717`): one stdout line
`nifmake-report <cmd>=<n> … total=<N>`, sorted, `total` always present.
`--profile` (`printProfile`, `:719-735`) goes to stderr.

## 5. How options reach the tools

`cli.parseCommonOption` is shared by `nimony` and `nimsem` only. Its
`forwardArg` (default true) makes `nimony.nim:303-316` append `--key:val` to
`c.commandLineArgs`, which `deps.emitFrontendArgs` (`:806-826`) splices into
the `nimsem` command of the `.build.nif`; `commandLineArgsLengc` does the same
for `lengc` (`deps.nim:1318-1321`). `nifler`, `hexer` and `nifmake` get no
forwarded arguments at all — their command definitions are fixed
(`defineNiflerCmd`, `defineHexerCmds`).

That matters for `--vfs`: putting the flag into `commandLineArgs` would put it
into the `.build.nif`, and two `--vfs` modes would then produce different
`.build.nif` bytes — which is exactly what the phase's gate ("byte-identical
artifacts") forbids the test from tolerating. So the flag is parsed in
`parseCommonOption` as the plan says, but it is *not* forwarded through the
build file: `nimony` exports it as an environment variable instead, which
every child (nifmake, and through it nifler/nimsem/hexer/lengc, and the nested
`nimony s` of a CTFE sub-compile) inherits automatically. Each tool reads
both, the flag winning, at startup.

## 6. Test harnesses to extend

- `tests/nifcache/setup.nim`: two in-process cases proving `bif.store` and
  `vfsWrite` never truncate a mapped file, plus a `.tmp.*` residue check.
  Extended with a mode comparison that drives `bin/nimony` twice.
- `tests/ctfe_diff/setup.nim` + `src/hastur/ctfediff.nim`: already takes two
  flag strings and compares every `*.out.nif`; only the two literals in
  `setup.nim:36` change.
- `src/hastur/incrementaltests.nim`: `incrementalTests()` and
  `incrementalOCacheTests()` build fixed command strings
  (`baseCmd`/`depCmd`/`ctfeCmd`, and a hardcoded cache directory). Both grow a
  `mode` parameter defaulting to `""` so the A1a agent's edits elsewhere in
  the file stay mergeable.
- `tests/vfs/` is new: host-Nim unit tests over `artifactstore.nim` directly.

---

# Phase A1b — what was built

## The store

`src/lib/artifactstore.nim`. One `ArtifactStore` per process, held in a
module-level `var` because the relays it installs are `nimcall` procs with no
context parameter — that is the shape `vfs.nim` defines, and everything else
in the module is threaded through the object explicitly.

`installArtifactStore(policy, budgetBytes)` captures all seven relays and
installs wrappers for all seven. `spDisk` installs nothing at all.

| policy | `--vfs:` | what it does |
|---|---|---|
| `spDisk` | `disk` | no adapter; today's behaviour exactly |
| `spMemory` | `memory` | resident entries; ephemeral paths never reach the disk; the budget drops rather than spills them |
| `spMemorySpill` | `memory+spill` | `memory`, plus `storeFlush` at the end of each tool's `main` and spilling under budget pressure |
| `spVerify` | `verify` | everything written through, every memory-answered read compared against the disk copy |

`--vfs-budget:<MB>` (default 512) caps residency. Over the budget the store
evicts, preferring an entry that is already on the disk (free) over one that
has to be written out first, and largest-first within each rank. A1d replaces
the size ranking with the ledger's "cheapest to reload".

## The write-through table

`crossProcessSuffixes` and `crossProcessDirs` document what the pipeline hands
to another process:

| group | suffixes |
|---|---|
| nifler -> nimsem | `.p.nif` `.p.deps.nif` `.pc.nif` `.pc.deps.nif` `.cfg.nif` |
| nimsem -> nimsem/hexer/deps | `.s.nif` `.s.idx.nif` `.s.deps.nif` `.sc.nif` `.sc.idx.nif` `.sc.deps.nif` |
| hexer -> dce -> shoggoth -> lengc | `.x.nif` `.dce.nif` `.live.nif` `.c.nif` `.oc.nif` `.types.nif` |
| CTFE result and P0a's read log | `.out.nif` `.out.nif.reads` |
| nimony -> nifmake | `.build.nif` (covers `.final`/`.final1`/`.final2`/`.doc`/`.exec`) |
| native backend, linker | `.asm.nif` `.in.nif` `.linkmanifest.nif` |
| not our tools at all | `.c` `.cpp` `.h` `.o` `.obj` `.ll` `.s` `.a` `.lib` `.dylib` `.so` `.dll` `.exe` `.wasm` |
| whole directories | `ocache/` (P0b), `ledger/` (A1a) |

`classifyPath` does **not** decide from that list. It answers
`pcCrossProcess` by default and consults `addEphemeralSuffix` — empty today —
for exceptions, and a documented suffix outranks a declaration. Getting the
default the other way round would turn a forgotten suffix into a silently
stale build (JIT.md 10); this way it costs a write nobody needed.

## The `runNodeRelay` seam

```nim
type
  RunNodeStatus* = enum
    RunSpawn, RunHandledOk, RunHandledFailed

  RunNodeRequest* = object
    name*: string        ## the `cmd` name from the DAG: `nifler`, `cc`, …
    command*: string     ## the fully expanded shell line
    inputs*, outputs*, args*: seq[string]
    baseDir*: string

var runNodeRelay*: proc (req: RunNodeRequest): RunNodeStatus {.nimcall.} =
  spawnEverything
```

Both paths of `runDag` call `offerNode`, which returns `RunSpawn` without
building the request while the relay is still the default. The sequential path
turns `RunSpawn` into `executeCommand`; the parallel path adds the node to the
batch `execProcesses` runs, and a handled node is counted as an executed
command so `--report` and `--profile` keep their meaning.

## Call sites converted

| file | what | count |
|---|---|---|
| `src/nifler/nifler.nim` | the re-parse and re-config staleness checks | 8 |
| `src/nifler/configcmd.nim` | `sourcesChangedImpl` | 3 |
| `src/nimony/semos.nim` | `lastModTimeOrStale`, `parseFile`, `writeFileIfChanged`, the `writenif` precompile probe | 7 |
| `src/nimony/programs.nim` | `needsRecompile` | 3 |
| `src/nimony/deps.nim` | `getLastModTime`, `execNifler`, `loadDepsFile`'s probe, the ocache digest, the cached-config memo | 8 |
| `src/nimony/macro_plugin.nim` | the plugin's `.p.deps.nif` and `macro_in_*.nif` | 2 |
| `src/hexer/intramodinliner.nim` | `findForeignFile` | 2 |
| `src/lengc/nifmodules.nim` | the foreign-module probe | 1 |
| `src/lengc/shoggoth/optdriver.nim` | `.c.nif` in, `.oc.nif` out | 2 |

36 expressions in 9 files. Everything else in the audit stayed direct:
directories (~12 sites), executables (~6), user sources and plugin-declared
data files (~20), debug-only dumps (~8), `nifmake`'s `generateMakefile`, and
the ~14 process-execution calls. The header of `artifactstore.nim` carries
that list with the reason per group.

## Deviations from the plan, and why

- **`--vfs` is not spliced into the `.build.nif`.** `JIT_IMPL.md` says
  "forwarded to every tool". Doing that through `commandLineArgs` would put
  the flag into the emitted build graph, and two modes would then produce
  different `*.build.nif` bytes — which is precisely what the phase's gate
  forbids. The flag is parsed in `cli.parseCommonOption` as specified, sets
  `forwardArg = false`, and the resolved policy is exported as `NIMONY_VFS` /
  `NIMONY_VFS_BUDGET`. Children inherit it: nifmake, and through it nifler,
  nimsem, hexer, lengc, and the nested `nimony s` of a CTFE sub-compile. Each
  tool also accepts the flag directly, which is what the tests drive.
- **`spillTo(dir)` is flat.** Entries are keyed by absolute path and the dump
  is meant to be read by name.
- **A blob is not served over an mmap miss.** `storeOpenMmap` answers from an
  entry the store already holds and otherwise lets the disk backend map the
  file. Copying the bytes in to hand back a pointer into them would cost more
  than it saves: JIT.md 3.3 measures mmap'd reads at ~0.1 ms per MB, and "disk
  is not the cost".
- **`bytesPtr` returns nil under nimony.** `hastur boot` compiles nimony,
  nimsem and hexer with nimony itself, and nimony rejects `addr s[0]`. A
  nimony-built compiler therefore installs the store but never serves an mmap
  from it. Every entry is written through today, so that is a missed cache
  hit and never a wrong answer.

## What is deliberately not here

- `memory` without write-through for anything: there is nothing to apply it to
  until phases share a process. The mechanism, the table and the tests exist;
  A2b and A2c populate `addEphemeralSuffix`.
- `erBif` and `erTokens` are declared and unused. A2 fills them.
- The ledger fields on an entry, the spill decision driven by
  `load + parse < produce`, and `--stats` are A1d.
