# Phase A2a-front — research notes

Written before editing, per `JIT_IMPL.md` "Execution rules for agents" rule 3.
Line numbers are from `fast-devloop` at `400c091e` (P0a, P0b, A1a, A1b, A1c
merged). Scope: `src/nifler/**`, `src/nimony/nimsem.nim`, `semmain.nim`,
`programs.nim`, `src/lib/nifpools.nim` and the reset procs the two sibling
sub-tasks (A2a-hexer, A2a-lengc) call.

## 1. How each tool reaches its phase today

| tool | CLI | phase entry | input | outputs |
|---|---|---|---|---|
| nifler | `nifler.nim:40 handleCmdLine` | `bridge.parseFile` (`bridge.nim:922`) | `llStreamOpen` on the `.nim` file | `.p.nif`, `.p.deps.nif`, both through a `nifbuilder.Builder` opened on the path |
| nimsem | `nimsem.nim:110 handleCmdLine` -> `processModules` | `semmain.semcheck` (`semmain.nim:710`) | `programs.setupProgram` -> `nifreader.open` + `nifcoreparse.parse` | `.s.nif` (`nifpools.writeFile`), `.s.idx.nif` (`nifindexes.createIndex`), `.s.deps.nif` (`writeNewDepsFile`) |

Both are process-shaped in the same two ways: every error path is a `quit`, and
the phase opens its own input and writes its own output from the inside.

### nifler emits TEXT, not tokens

The AST->NIF walk (`bridge.toNif`) writes through `nifbuilder.Builder`, whose
whole API is textual (`addTree`, `addIdent`, `addStrLit`, `endTree`); there is
no `TokenBuf` anywhere in nifler. A file-mode `Builder` accumulates in a string
and flushes once at `close()` via `vfsWrite`, and a memory-mode one hands the
same string over with `extract()` — the bytes cannot differ between the two.

So `parseToBuf` returns the `.p.nif` and `.p.deps.nif` **as strings**. Making it
return a `TokenBuf` would mean either re-parsing the text we just rendered (a
waste, and the consumer may not want tokens) or rewriting every emission call in
`bridge.nim` against `nifcore`'s builder API — a rewrite of the tool, not an
entry point. A caller that wants tokens runs `nifpools.parseFromBuffer` over
`code`, which is exactly what nimsem's side of the handoff does anyway.

### nimsem's input and outputs

`semcheck` materialises the whole `.s.nif` as a `TokenBuf` (`dest`) before any
I/O, so a buffer-returning variant is a matter of stopping before the three
writes. Two things had to move for that:

- `nifindexes.createIndex` re-read the module it had just written (mmap +
  parse) to checksum it. Split into `indexContent(infile, nifContent, …)` (pure)
  and `writeIndex`; `createIndex` is now that read plus those two, with
  `vfsRead` in place of the mmap so one code path serves both callers. The
  checksum is taken over a parse of the exact bytes either way, so the
  file-level and buffer-level callers cannot drift apart.
- `nifpools.writeFile` was render + write in one. Split into `renderModule` and
  `writeRendered`, so a phase can produce its bytes without deciding where —
  or whether — they are stored.

**The file path keeps its read-back.** `buildOutputs` renders the module and
could hand `writeOutputs` a finished index, saving a read and a parse per
module. It does not: `writeOutputs` writes the module and lets `createIndex`
read it back, exactly as before. That read is the only place in a small build
where one process reads a file it wrote itself, and `tests/nifcache` counts it
to prove `--vfs:verify` is not a no-op (`verify=0` fails the suite). Skipping
it is what running the phase in-process buys — `indexBytes` is that door — not
something to change under the tools that still spawn.

## 2. What the new surface is

```nim
# src/nifler/bridge.nim
type ParsedModule* = object
  code*, deps*: string     # the .p.nif and .p.deps.nif bytes
  ok*: bool
  msg*: string             # "" when the Nim parser already reported

proc parseToBuf*(thisfile: string; portablePaths, depsEnabled, depsOnly: bool;
                 preserveDocs = false): ParsedModule
proc writeParsed*(m: ParsedModule; outfile: string; depsEnabled, depsOnly: bool)
proc parseFile*(...)                       # = parseToBuf + writeParsed, quits

# src/nifler/nifler.nim
proc runNifler*(argv: seq[string]): int
proc resetNiflerGlobals*()

# src/nimony/semmain.nim
type SemOutputs* = object
  code*: TokenBuf          # the .s.nif as tokens
  text*: string            # the same module rendered — the bytes on disk
  sections*: IndexSections # what the .s.idx.nif is built from
  deps*: TokenBuf          # the .s.deps.nif as tokens
  ok*: bool

proc loadInput*(infile: string; timer: var PhaseTimer): TokenBuf
proc semcheckToBuf*(input: var TokenBuf; infile, outfile: string; config: sink NifConfig;
                    moduleFlags: set[ModuleFlag]; commandLineArgs: sink string;
                    canSelfExec: bool; timer: var PhaseTimer): SemOutputs
proc indexBytes*(o: var SemOutputs; outfile: string): string  # no file needed
proc writeOutputs*(o: var SemOutputs; outfile: string)
proc semcheckToFiles*(...; timer: var PhaseTimer): bool   # load+sem+write
proc semcheck*(...)                                       # quits on error (nimony.nim)
proc resetFrontendGlobals*()

# src/nimony/nimsem.nim
proc runNimsem*(argv: seq[string]): int

# src/lib/nifpools.nim
proc resetPools*()
proc renderModule*(b: var TokenBuf; filename: string): string
proc writeRendered*(filename, content: string; mode = AlwaysWrite)

# src/nimony/programs.nim
proc resetProgram*()
proc setupProgramFromBuf*(infile, outfile: string; input: var TokenBuf): Cursor
```

`resetFrontendGlobals` is the one the hexer and lengc sub-tasks call.

## 3. Every process-global `var` in scope, and what it costs

`grep -n '^var' src/nimony/*.nim src/lib/*.nim src/nifler/**/*.nim` plus a sweep
for `{.global.}` (none) and `.compileTime` (none). `src/nifler/**` declares no
module-level state at all.

| file:line | var | reset by | what breaks without a reset |
|---|---|---|---|
| `src/lib/nifpools.nim:65` | `globalTags` | `resetPools` | the tag namespace; must be re-seeded in `TagEnum` order by `createMasterTagPool`, or every `cast[NimonyPragma](raw)` decodes garbage |
| `src/lib/nifpools.nim:76` | `pool` | `resetPools` | every interned string/sym/filename. `SymId`s are what the `.s.nif` carries, so module 2 inherits module 1's numbering; worse, a same-spelled symbol gets module 1's `SymId` back and `prog.mem` serves module 1's decl for it |
| `src/lib/nifcore.nim:445,451` | `fallbackPool`, `fallbackTags` | `resetPools` (re-pointed) | they are a value copy taken at `nifpools` module init, not an alias — reassigning `pool` without re-pointing them splits the process between two pools |
| `src/nimony/programs.nim:74` | `prog` | `resetProgram` | `.mods` caches every dependency `NifModule` (a live `Reader` and its index tables) keyed by suffix; `.mem` caches every published toplevel by `SymId`; `.main` is the module being compiled. All three are keyed by ids of the pool above |
| `src/nimony/identstyle.nim:27` | `styleGroups`, `styleHighWaterMark` | `resetStyleTables` | the watermark is a raw index into `pool.strings`. Reset the pool alone and it points past the end of the fresh, smaller pool: `ensureStyleGroups` then never indexes another string and `ignoreStyle` lookups silently stop finding siblings |
| `src/nimony/identstyle.nim:88` | `pragmaStyleIndex` | `resetStyleTables` | keyed by `StrId`s of the old pool. Its *content* is a constant mapping, so leaving it would not be wrong across modules — but it would be wrong across a pool reset |
| `src/lib/filelinecache.nim:27` | `gFileLineCache` | `resetFileLineCache` | file contents cached by path for diagnostics. Same path, edited between two in-process compiles (the dev loop of `JIT.md` 6.1) → the error quotes the old source |
| `src/lib/artifactstore.nim:207,600` | `store`, `request` | `uninstallArtifactStore` (A1b), deliberately NOT by us | process-wide `--vfs` policy; resetting it per phase would throw away the store the scheduler is built on |
| `src/lib/vfs.nim:247-266` | the seven `*Relay`s | `uninstallArtifactStore` | same |
| `src/lib/vfs.nim:53-59` | `stat*` counters (`-d:vfsProfile`) | — | a diagnostic total; double counting across two runs is the correct reading |
| `src/lib/vfs.nim:98` | `atomicWriteCounter` | — | wants to keep growing: it exists for process-wide temp-name uniqueness |
| `src/lib/toolhash.nim:34` | `cachedToolhash` | — | process identity, not module state |
| `src/lib/nifstreams.nim:49,120` | `lineMan`, `globalFloats` | — | the classic surface for the frozen Nim compiler's IC modules. Confirmed unreferenced from `src/nimony` and `src/nifler`; the frontend speaks `nifcore.NifLineInfo` directly (`nifpools.nim`'s header says so) |
| `src/lib/artifactstore.nim:381` | `storeFatalRelay` | — | a test-swappable hook, not data |

Clean (no module-level state): `nifindexes`, `foreignmodules`, `nifreader`,
`nifbuilder`, `stringviews`, `symparser`, `lineinfos` (its `LineInfoManager` is
always a `var` parameter), `bitabs`, `nifcoreparse`, `nifchecksums`, `bif`,
`ledger`, and every other `src/nimony/*.nim` — `SemContext` and `Reporter` are
threaded objects, not globals.

### One global that cannot be reset

The host Nim compiler's `ast.gconfig.comments` threadvar
(`$nim/compiler/ast.nim:846`) maps a `PNode`'s **address** to its doc comment
and is never pruned — the file says so in a `when false` cleanup block. nifler
writes into it for every `##` comment. It is not exported and has no clearing
proc, so `resetNiflerGlobals` cannot touch it. It costs memory in a long-lived
process; it cannot change the output, because entries are only read through the
node that owns the address while that node is alive.

## 4. Is `semCompiles`'s save/restore enough for A2c?

`semmagics.semCompiles` (`semmagics.nim:131`) saves and restores, all on the
`SemContext`: `currentScope`, the lengths of `procRequests`, `typeInstDecls`,
`instantiatedFrom`, `includeStack` and `expanded`, plus `inWhen`,
`templateInstCounter` and `debugAllowErrors`; and it shrinks `dest` back to
where the trial started.

**Not sufficient for A2c on its own.** It is a *within-module* trial: it
restores the fields a speculative `semExpr` is known to append to, and nothing
else. Re-entrant sem for a CTFE snippet is a different animal:

- It publishes into `prog.mem` and can load modules into `prog.mods`
  (`publish`, `publishSignature`, `programs.load`). `semCompiles` restores
  neither, because a trial that publishes a symbol is already a bug within one
  module — but a snippet legitimately does.
- It interns into `pool`/`globalTags`, which is fine (interning is monotone and
  shared on purpose) and is exactly why the snippet must NOT run after a
  `resetPools`: the parent's live `SymId`s would stop meaning anything.
- It appends to fields `semCompiles` does not know about: `importedModules`,
  `exports`, `converterIndexMap`, `toBuild`/`toBundle`/`passL`/`passC`/
  `fileDeps`, `matchedForwardDecls`, `pendingSumtypes`, `genericInnerProcs`,
  `typeHooks`, `classes`. Each of those lands in the parent's `.s.nif`,
  `.s.idx.nif` or `.s.deps.nif` if the snippet leaves anything behind.

So A2c has two options, and the plan already names them: run the snippet's sem
in a **fresh `SemContext` sharing `prog` and the pool** (no reset at all — the
snippet must see the parent's symbols) and keep the parent's `SemContext`
untouched, or extend the save/restore set to every appending field listed above.
The first is the honest one; `resetFrontendGlobals` is for the *scheduler*
running two unrelated modules back to back, not for a nested evaluation.

## 5. Deviations and things left path-based

1. **Imports stay path-based.** `programs.load` reads an imported module's
   `.s.nif` and `.s.idx.nif` from disk by suffix, and `foreignmodules` mmaps
   `bif` modules. The buffer level here is the phase's own input and outputs, as
   `JIT_IMPL.md` allows. A2b's store hands those files to the phase through the
   VFS relays, which is the seam that already exists for them.
2. **The cycle-group path stays file-based.** `semcheckCycleGroup` writes its
   members as a unit; `semcheckToBuf` is the single-module entry. A cycle group
   is one ledger sample, as before.
3. **`setupProgramFromBuf` registers the main module without a reader.** A
   reader is only ever used to jump to an index entry (`programs.nim:349`), and
   the main module has no index (`setupProgram` passes `hasIndex = false`), so
   the field is dead for it. Documented at the proc.
4. **`createIndex` now reads its module with `vfsRead` instead of mmapping it.**
   One extra copy of the bytes per module, one code path shared with the
   buffer-level caller, and one fewer thing that can keep a file locked on
   Windows. It is still a read through the store, which is what
   `tests/nifcache` asserts.
5. **Files touched outside the phase's own list**, all additively:
   `src/lib/nifindexes.nim` (the `indexContent`/`writeIndex` split — no other
   A2a sub-task touches it), `src/lib/filelinecache.nim` (a six-line reset
   proc), `src/nimony/identstyle.nim` (ditto — it is named in the phase's brief
   as "identstyle tables").
6. **`--help`/`--version` still `quit`.** `cli.parseCommonOption` (shared with
   `nimony.nim`, owned by another sub-task) quits for them. No in-process
   caller passes them; every other `quit` on nimsem's and nifler's library path
   is now a returned exit code with the same bytes on stderr.

## 6. Ledger seams now filled (A1a left them at 0)

`nifler`: `produce` = read + parse + render (nifler renders as it walks, so
there is no separate serialize step), `write` = the two `writeIfChanged`s.
`nimsem`, single module: `load` = open the `.p.nif`, `parse` = parse it,
`produce` = sem, `serialize` = render + index + deps, `write` = the three
writes. Cycle group: one `produce`, as before.
