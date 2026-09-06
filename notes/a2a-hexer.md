# Phase A2a-hexer — research notes

Written before the implementation, per `JIT_IMPL.md` "Execution rules for
agents" rule 3. Worktree branch `jit/a2a-hexer`, forked from `fast-devloop`
(`400c091e`, i.e. with P0a, P0b, A1a, A1b and A1c already in).

Owner files: `src/hexer/**` and the new `tests/inproc/hexer/`. `src/lib/**`,
`src/nimony/**`, `src/lengc/**`, `src/nifler/**` and `src/nifmake/**` belong to
other agents in this wave; where hexer needed something from one of them the
workaround is local and the wanted shared change is listed in section 6.

---

## 1. The four entry points and where they touch a file

`src/hexer/hexer.nim` has **four** sub-commands, not the two its `Usage`
banner documents:

| action | proc | inputs | outputs |
|---|---|---|---|
| `c` | `lengcgen.expand` (`lengcgen.nim:2798`) | `<M>.s.nif` (+ `<M>.s.idx.nif`) | `<dir>/<M>.x.nif`, `<dir>/<M>.dce.nif` |
| `d` | `dce2.deadCodeElimination` (`dce2.nim:209`) | every `<M>.x.nif` + its `.dce.nif` | every `<M>.c.nif` |
| `dl` | `dce2.computeLiveSet` (`dce2.nim:318`) | `<M>.dce.nif`… | `<main>.live.nif` |
| `de` | `dce2.dceEmit` (`dce2.nim:335`) | `<M>.x.nif`, `<main>.live.nif` | `<outdir>/<M>.c.nif` |

`d` is the legacy single-process path; `deps.generateFinalBuildFile` emits
`dl` + one `de` per module so the rewrite fans out. Nothing outside
`hexer.nim` calls any of the four (`grep` over `src/` and `tests/`), so their
signatures are free.

The whole file surface of `src/hexer` is five expressions:

| file:line (before A2a) | expression | what |
|---|---|---|
| `lengcgen.nim:2823` | `setupProgram(infile, …, owningBuf, true)` | read+index+parse the `.s.nif` |
| `lengcgen.nim:2869` | `writeFile outputBuf, destfileName, OnlyIfChanged` | the `.x.nif` |
| `lengcgen.nim:2875` | `writeDceOutput outputBuf, …` -> `dce1.nim:86` `nifbuilder.open` | the `.dce.nif` |
| `dce2.nim:195,205` | `parseFromFile(file)` / `writeFile(dest, outPath, …)` | `.x.nif` -> `.c.nif` |
| `dce2.nim:246,267` | `nifbuilder.open(outfile,…)` / `parseFromFile(infile)` | the `.live.nif` |

plus `intramodinliner.nim:352,354` (`vfsExists` probes for a foreign module,
already relayed by A1b) and `passes.nim:43` (`open(env, fmAppend)`, the
`NIMONY_PASS_TIMING` diagnostic log, not part of the data flow).

Everything between those five is already `TokenBuf` -> `TokenBuf`:
`pipeline.transform` chains ten passes through one `Pass` object,
`optimizeLengOutput` runs `runArcopt` / `annotateFunctionSummaries` /
`intraModuleInline`, and `dce2.tr` walks a cursor into a buffer. That is what
JIT.md 3.1 means by "only the first and last lines touch files", and it is
why this phase is a re-plumbing rather than a rewrite.

## 2. Object lifetimes

`EContext` (`hexer_context.nim:24`), `Pass` (`passes.nim:15`), `Con`
(`arcopt.nim`), `InlinerCtx` (`intramodinliner.nim`) and every pass-local
`Context` are constructed inside the call that uses them and die with it.
There is no pipeline object with a cross-invocation lifetime, so nothing in
`src/hexer` needs a teardown.

`ResolveTable` (`dce2.nim:21`, `Table[string, SymId]`) maps an
instantiation's module-less key to the `SymId` that owns it. It is rebuilt on
every `computeLiveSet` and reaches `dceEmit` only through the `.live.nif`.
`LiveSet` (`dce2.nim:261`) already pairs it with the per-module live sets;
that object is what A2c caches.

## 3. Module-level state

A scan of every `var`/`let`/`{.global.}` at every indentation depth over all
26 files of `src/hexer` finds **three** module-level variables, all of them
under a `when`:

| file:line | declaration | two-run hazard |
|---|---|---|
| `passes.nim:32-35` | `passTimingInited: bool`, `passTimingLog: File`, `passTimingEnabled: bool` (`when not defined(nimony)`) | none worth fixing. `ensurePassTimingInit` is a once-guard around `NIMONY_PASS_TIMING`; a second run keeps appending to the same handle, which is what the module's own comment asks for. Only a run that wanted a *different* log file would be surprised. |
| `intramodinliner.nim:1270` | `inlinerStats*: Table[string, tuple[count, tokens: int]]` (`when defined(inlinerStats)`) | accumulates: run 1 + run 2 would be reported as one number by `dumpInlinerStats`. Reset. |

That is the whole list. Everything else is threaded through an explicit state
object, which is AGENTS.md's rule and happens to be exactly what a re-entrant
tool needs.

The state that actually matters is one layer down, in modules this phase may
not edit. Hexer's transitive graph is `hexer.nim` -> the passes ->
`nimony/[programs, typenav, expreval, decls, builtintypes, sizeof, typeprops,
langmodes, typekeys, nifconfig, nimony_model]` -> `lib/[nifpools, nifbuilder,
bitabs, symparser, nifindexes, vfs, artifactstore, ledger]` -> `nifcore`.
`lib/nifstreams.nim` is **not** in it.

| file:line | declaration | two-run hazard |
|---|---|---|
| `nimony/programs.nim:73` | `prog*: Program` (`mods`, `main`, `mem`) | **the one that can change hexer's output.** `setupProgram` overwrites `prog.main` and adds `prog.mods[main]`, never clears. Run 2's `load(suffix)` / `tryLoadSym` would be answered out of run 1's `prog.mods` and `prog.mem` — run 1's bytes for a file that changed on disk in between. |
| `lib/nifpools.nim:65,76` | `globalTags*`, `pool*` | interning tables keyed by text. Two runs asking for the same symbol name *should* get the same `SymId`, and every serializer writes names. Sharing them is correct; they grow, which is a memory cost, not a correctness one. |
| `lib/nifcore.nim:445,451` | `fallbackPool*`, `fallbackTags*` | aliases of the two above, assigned once at `nifpools` import. Must move in lockstep with them or not at all. |
| `lib/artifactstore.nim:207,381,600` | `store`, `storeFatalRelay*`, `request` | `store` and the seven `vfs` relays are the *caller's* `--vfs` policy; `uninstallArtifactStore` (`:562`) already exists and its own comment says "A2a wants the same reset". `request` (the parsed flag) is private and has no reset — see section 6. |
| `lib/vfs.nim:98` | `atomicWriteCounter` | write-only temp-path sequence; must **not** be reset. |
| `lib/[lineinfos, nifbuilder, symparser, nifindexes, ledger]`, `nimony/[nifconfig, typekeys, langmodes, decls, typenav, sizeof, xints]` | — | no module-level state at all. |

No `reset*` proc exists anywhere in `src/` today except
`artifactstore.uninstallArtifactStore`.

## 4. `PhaseTimer` (A1a)

`src/lib/ledger.nim:542-597`. `mark()` starts a region; each `note*` charges
the interval since the previous mark/note to its bucket and moves the mark on.
`initPhaseTimer(dir, phase, module)` with an empty `dir` or `phase` yields an
**inactive** timer whose `note*` and `finish` are no-ops — that is how the
untimed wrappers below stay free.

Before A2a, `hexer.nim` was the only caller in the tree and only ever called
`noteProduce`, because the phase procs did load+parse+produce+serialize+write
in one call. `notes/a1a.md` section 6 records that as deviation 6 and names
A2a as the phase that fixes it.

## 5. `hastur` custom runners

`walk.collectTests` (`walk.nim:96`) treats a directory holding `setup.nim` as
a leaf that owns its whole subtree; `runSetupNimDir` (`walk.nim:37`) compiles
it with `nim c -r` and passes `--dir`, `--bindir`, `--cachedir` (plus
`--overwrite`/`--forward`). **The runner's exit code is the whole verdict.**
A directory with no `.nim` file of its own and no runner marker is a grouping
directory the walk descends through — which is why `tests/inproc/` itself must
stay free of `.nim` files while `tests/inproc/hexer/setup.nim` is the runner.

---

# Phase A2a-hexer — what was built

## The signatures

`src/hexer/lengcgen.nim`:

```nim
type
  ExpandInput* = object
    buf*: TokenBuf            ## the parsed `.s.nif`
    modName*, ext*, dir*: string

  ExpandResult* = object
    x*: TokenBuf              ## the `.x.nif` module
    dce*: ModuleAnalysis      ## what `.dce.nif` serializes
    modName*, dir*: string

proc expandDir*(infile, outdir: string; s: var HexerStatus): string
proc loadExpandInput*(infile, outdir: string; bits: int; t: var PhaseTimer;
                      s: var HexerStatus): ExpandInput
proc expand*(input: var ExpandInput; bigEndian: bool; flags: set[CheckMode];
             isMain: bool; appType = appConsole; native = false;
             isWindows = defined(windows)): ExpandResult
proc xnifPath*(r: ExpandResult): string
proc dcenifPath*(r: ExpandResult): string
proc writeExpandResult*(r: var ExpandResult; t: var PhaseTimer; s: var HexerStatus)
proc expand*(infile: string; bits: int; bigEndian: bool; flags: set[CheckMode];
             isMain: bool; outdir: string; t: var PhaseTimer; s: var HexerStatus;
             appType = appConsole; native = false; isWindows = defined(windows))
proc expand*(infile: string; bits: int; bigEndian: bool; flags: set[CheckMode];
             isMain: bool; outdir: string; s: var HexerStatus;
             appType = appConsole; native = false; isWindows = defined(windows))
```

`ExpandInput` carries `bits`, the `TypeCache` and the `LiftingCtx` because
`loadExpandInput` has to build the type cache BEFORE it parses the module --
see "Two decisions worth stating" below.

`src/hexer/dce1.nim`:

```nim
proc analyzeModule*(n: Cursor): ModuleAnalysis
proc writeAnalysis*(outputFilename: string; a: var ModuleAnalysis; dottedSuffix: string)
proc parseAnalysis*(n0: Cursor; ctx: string): ModuleAnalysis
proc readModuleAnalysis*(infile: string): ModuleAnalysis
proc readModuleAnalysis*(infile: string; t: var PhaseTimer): ModuleAnalysis
```

`src/hexer/dce2.nim`:

```nim
type
  ResolveTable* = Table[string, SymId]
  LiveSet* = object
    resolved*: ResolveTable
    live*: Table[string, HashSet[SymId]]
  DceInputs* = object
    names*: seq[string]              ## `names[0]` is the main module
    analyses*: seq[ModuleAnalysis]

proc addAnalysis*(inp: var DceInputs; name: string; a: sink ModuleAnalysis)
proc computeLiveSet*(inputs: DceInputs): LiveSet                 # buffer level
proc loadDceInputs*(dceFiles: openArray[string]; t: var PhaseTimer): DceInputs
proc computeLiveSet*(dceFiles: openArray[string]; liveOut: string; t: var PhaseTimer)
proc computeLiveSet*(dceFiles: openArray[string]; liveOut: string)
proc writeLiveFile*(outfile: string; resolved: ResolveTable; live: Table[string, HashSet[SymId]])
proc writeLiveFile*(outfile: string; ls: LiveSet)
proc parseLiveSet*(n0: Cursor; ctx: string): LiveSet
proc readLiveFile*(infile: string): LiveSet
proc readLiveFile*(infile: string; t: var PhaseTimer): LiveSet
proc liveOf*(ls: LiveSet; modName: string): HashSet[SymId]
proc rewriteBuf*(xbuf: var TokenBuf; live: HashSet[SymId]; resolved: ResolveTable): TokenBuf
proc emitOutPath*(xnif, outdir: string): string
proc dceEmit*(xnif: string; ls: LiveSet; outdir: string; t: var PhaseTimer;
              s: var HexerStatus)
proc dceEmit*(xnif, liveFile, outdir: string; t: var PhaseTimer; s: var HexerStatus)
proc dceEmit*(xnif, liveFile, outdir: string; s: var HexerStatus)
proc deadCodeElimination*(files: openArray[string]; outdir: string;
                          s: var HexerStatus)
```

`src/hexer/hexer.nim`:

```nim
proc runHexer*(args: seq[string]): int
proc resetHexerGlobals*()
proc handleCmdLine*()          ## the CLI shell: runHexer(commandLineParams())
```

`src/hexer/hexerio.nim` (new):

```nim
type
  HexerStatus* = object
    msg*: string          ## "" is success; otherwise the CLI's stderr line

proc fail*(s: var HexerStatus; msg: string)
proc failed*(s: HexerStatus): bool
proc loadAndParse*(filename: string; t: var PhaseTimer; sizeHint = 100): TokenBuf
proc serializeModule*(b: var TokenBuf; filename: string): string
proc writeSerialized*(content: string; filename: string; mode: FileWriteMode;
                      s: var HexerStatus)
```

`HexerStatus` and not an exception because hexer is compiled by BOTH Nim and
nimony (`hastur boot` self-hosts it), and nimony's `raise` carries an
`ErrorCode`, not a message: `newException(IOError, msg)` does not exist in
that dialect. This was found the hard way — the first implementation raised
and `hastur boot` stage 1 rejected it with *"expected: typedesc[T] but got:
ErrorCode"*. A status object is also the shape `JIT_IMPL.md` names first
("becomes a returned error") and is AGENTS.md's explicit-state-object rule.

## Two decisions worth stating

**The `.dce.nif` output is an object, not a buffer.** `expand` hands back a
`ModuleAnalysis`, which is what `computeLiveSet` consumes, rather than the
serialized `(stmts (roots …) (uses …) (offers …))`. The in-process path then
never serializes and re-parses it at all. The file representation stays
exactly what it was: `writeAnalysis` is the old `prepDce` body verbatim, so
the `.dce.nif` bytes are unchanged.

**`LiveSet` is the cacheable object A2c wants.** `ResolveTable` is now
exported, `readLiveFile` is separate from `parseLiveSet`, and
`dceEmit(xnif, ls, outdir, t, s)` takes the object — so one `.live.nif` read
serves N modules in one process instead of N reads.

**The `TypeCache` is built before the parse, and that is load-bearing.**
`ExpandInput` carries it because `builtintypes.createBuiltinTypes` interns
`StringName` (`src/nimony/builtintypes.nim:146`). Pre-A2a, `expand` built its
`EContext` (and therefore the type cache) and only then called
`setupProgram`; the obvious refactor — "read the file, then run the phase" —
inverts that, `StringName` lands after every symbol of the module, and every
`SymId` shifts by one. Nothing about the `.x.nif` changes (it renders names),
but `.dce.nif` and `.live.nif` serialize `HashSet[SymId]` and
`Table[_, SymId]` in hash order, so the same symbols come out SHUFFLED.
Caught by a direct comparison against a pre-A2a binary, not by any existing
test — worth knowing for A2a-lengc and A2a-front, which have the same shape
of seam.

**The pool has to be reset between two in-process runs, for the same reason.**
`resetHexerGlobals` therefore does `pool = newPool(); fallbackPool = pool`
beside `prog = default(Program)`. `tests/inproc/hexer` fails two of its nine
checks without it — the second `hexer c` and the `dl` — and passes all nine
with it. JIT.md 6.1 already named `pool` in the reset set; this is why.

## The ledger split

`hexer c`: `parse` = `loadExpandInput` (see the caveat below), `produce` = the
buffer-level `expand`, `serialize` = rendering the `.x.nif`, `write` = both
publishes. `hexer de`: `load`/`parse` are the `.live.nif` and the `.x.nif`
reads with the reader open and the token build charged apart, then `produce`,
`serialize`, `write`. `hexer dl`: `load`/`parse` per `.dce.nif`, then
`produce` and `write` (`nifbuilder` renders as it builds, so there is no
separate serialize step to measure).

`noteLoad` stays 0 for `hexer c` alone, and that is not an oversight:
`programs.setupProgram` opens the reader, folds in the embedded index, reads
`.s.idx.nif` and parses the module in a single call. Splitting it needs the
change in section 6.

## Deviations from the plan

- **The pre-A2a signatures gained a `HexerStatus` parameter.** They could not
  keep their exact shape and stop calling `quit`: the failure has to leave the
  proc somehow, and in the nimony dialect it cannot ride an exception. Nothing
  outside `hexer.nim` called any of the four procs, so no call site outside
  this phase's owner files is affected.
- **`expand`'s buffer overload takes an `ExpandInput`, not a bare `Cursor`.**
  `JIT.md` 6.1 sketches `expand(Cursor): TokenBuf`. A bare cursor is not
  enough: `setupProgram` also registers the module in `prog` so that
  `tryLoadSym` can jump into the module's *own* `.s.nif` through its index,
  and `NifModule` plus `Program.mods` are private to `src/nimony/programs.nim`.
  So `loadExpandInput` is the "read" step, `expand(input, …)` is genuinely
  file-free, and closing the last gap is a `programs.nim` change (section 6).
- **`EContext.error` still calls `quit 1`.** It is the compiler's own
  diagnostic path (`hexer_context.nim:94-107`, `{.noreturn.}`), reached from
  ~200 call sites deep inside the passes, not the CLI path. Turning it into a
  status return is a phase of its own; until then a malformed input kills a
  caller that runs hexer in-process. Same for `nifreader.open`'s
  `quit "cannot open: <path>"` (`src/lib/nifreader.nim:569`), which is what a
  missing input file hits. Recorded as risks, not fixed here.
- **`hexer dl` has no `HexerStatus`.** `writeLiveFile` publishes through
  `nifbuilder.close`, which is exactly what it did before A2a; adding a status
  there would mean changing `nifbuilder`, which is `src/lib`.

---

## 6. Shared-module changes wanted from the integrator

None of these is required for A2a to be correct; each removes a local
duplicate or a remaining seam.

1. **`src/lib/nifpools.nim`: expose the halves of `writeFile` and
   `parseFromFile`.** `hexerio.nim` currently carries a copy of each:
   `serializeModule` + `writeSerialized` are `writeFile`'s renderer and its
   `OnlyIfChanged` write, and `loadAndParse` is `parseFromFile` with the
   reader open separated from the token build. Wanted:
   ```nim
   proc serializeModule*(b: var TokenBuf; filename: string): string
   proc writeSerialized*(content: string; filename: string; mode: FileWriteMode)
   proc parseFromFileSplit*(filename: string; afterOpen: proc ...)  # or two procs
   ```
   Two copies of the same three lines is two places to keep in step, and the
   ledger's `load`/`parse`/`serialize`/`write` split is wanted by lengc and
   nimsem too.
2. **`src/nimony/programs.nim`: a way to register a module from a buffer.**
   `setupProgram(infile, outfile, owningBuf, hasIndex)` is the last file read
   in `hexer c`. What A2b/A2c need is
   ```nim
   proc setupProgramFromBuf*(suffix, dir, ext: string; content: var TokenBuf;
                             index: NifIndex)
   ```
   or, minimally, `newNifModule` over a `nifreader.openFromBuffer` plus a
   public `prog.mods` setter. Without it the in-process path still reads the
   `.s.nif` from disk, and `noteLoad` for `hexer c` stays 0.
3. **`src/nimony/programs.nim`: `resetProgram*()`.** `resetHexerGlobals`
   assigns `prog = default(Program)` from the outside. That works (only the
   fields are private, not the type), but the reset belongs next to the
   variable, and A2a-front's `resetFrontendGlobals` is where it should live —
   at which point `resetHexerGlobals` calls that instead.
4. **`src/lib/artifactstore.nim`: `resetStoreRequest*()`.** `request` (what
   `--vfs` / `--vfs-budget` parsed) is private and survives a
   `resetHexerGlobals`, so a second `runHexer` with no `--vfs` inherits the
   first one's policy. One three-line proc next to `requestStorePolicy`.
5. **`src/hexer/hexer_context.nim`'s `error` should raise.** Not a shared
   module, but it is the one remaining `quit` on a path a library caller can
   reach, and turning it into a `CatchableError` touches every pass. Left for
   its own phase.

## 7. Verified byte-identity

Against a `bin/hexer` built from `fast-devloop` at `400c091e`, on the fixtures
`tests/inproc/hexer` builds:

- `hexer c` on both modules: `.x.nif` and `.dce.nif` identical.
- `hexer dl` over the five-module closure: `.live.nif` identical.
- `hexer de` on both modules: `.c.nif` identical.
- 15 CLI cases — `--help`, `-h`, `--version`, `-v`, no arguments, an unknown
  flag, an unknown action, each of `--bits`/`--cpu`/`--app`/`--vfs`/
  `--vfs-budget` with a bad value, `c` with two files, `dl` with one, `de`
  with one — identical in stdout, stderr AND exit code. Plus the two failure
  paths that used to `quit` from inside a phase: a missing input
  (`[Error] cannot open: …`, 1) and an unwritable `--outdir`
  (`could not write file: …`, 1).

## 8. Tests

`tests/inproc/hexer/setup.nim` builds two small modules' `.s.nif` inputs with
`bin/nimony c --nimcache:<tmp>`, then:

- **section A**: compiles a host-Nim driver that imports `src/hexer/hexer`,
  calls `runHexer` twice in one process on the two different `.s.nif` inputs
  with `resetHexerGlobals()` in between, and compares the resulting
  `.x.nif`/`.dce.nif` with what two separate `bin/hexer` processes produce.
- **section B**: the same for the split DCE (`dl` then `de` per module),
  comparing the `.live.nif` and both `.c.nif`s.
- **section C**: the buffer overload — `loadExpandInput` + `expand(input, …)`
  + `serializeModule` against the bytes the path-based `expand` wrote.

`tests/inproc/` holds no `.nim` file of its own so the tree walk descends into
it (`walk.collectTests`).
