# Phase A2a-lengc — research notes

Written before editing, per `JIT_IMPL.md` "Execution rules for agents" rule 3.
Line numbers are from `fast-devloop` at `400c091e` (P0a, P0b, A1a, A1b and A1c
merged). Owner files: `src/lengc/**` and the new `tests/inproc/lengc/`.

## 1. The CLI (`src/lengc/lengc.nim`, 240 lines)

`handleCmdLine` (line 90) is the whole tool. It builds one
`State(config: ConfigRef(), bits: sizeof(int)*8)` (98), walks `getopt()` (106)
into an `ActionTable = OrderedTable[Action, seq[string]]`, then dispatches.
Nothing is stored anywhere else: `State` and `ConfigRef` are the only carriers
of configuration and both are created inside this proc.

Commands (bare arguments, 108-137): `c` -> `atC`, `cpp` -> `atCpp`,
`n` -> `atNative`, `llvm` -> `atLLVM`. Any other bare argument is appended to
the current action's file list; one before any command quits with
`"invalid command: " & key`.

Options (138-200): `--bits:64|32|16`, `--help`/`-h`, `--version`/`-v`,
`--run`/`-r`, `--compileOnly`, `--isMain`, `--cc:gcc|clang`,
`--opt:none|speed|size`, `--lineDir:on|off`, `--nimcache:PATH`, `--out`/`-o`,
`--app:console|gui|lib|staticlib`, `--vfs:...`, `--vfs-budget:MB`. Anything
else falls through to `writeHelp()`.

The exit paths, all of them `quit`, with the exact text and code:

| where | text | code |
|---|---|---|
| `writeHelp` (53) | `Usage` | 0 |
| `writeVersion` (54) | `Version & "\n"` | 0 |
| `generateBackend` (67), `generateLLVMBackend` (81), `atNative` with no files (215) | `command takes a filename` | 1 |
| cmdArgument, no action yet (136) | `invalid command: <key>` | 1 |
| `--bits` (144) | `invalid value for --bits` | 1 |
| `--cc` (156) | `unknown C compiler: '<val>'. Available options are: gcc, clang` | 1 |
| `--opt` (166) | `'none', 'speed' or 'size' expected, but '<val>' found` | 1 |
| `--lineDir` (175) | `'on', 'off' expected, but '<val>' found` | 1 |
| `--app` (191) | `invalid value for --app; expected console, gui, lib, or staticlib` | 1 |
| `--vfs` (194) | `invalid value for --vfs; expected disk, memory, memory+spill or verify` | 1 |
| `--vfs-budget` (198) | `invalid value for --vfs-budget; expected a size in megabytes` | 1 |
| `atNative` without `-d:enableAsm` (222) | `wasn't built with native target support` | 1 |
| `atNone` (228) | `targets are not specified` | 1 |

`quit(msg, code)` in Nim 2.2.10 (`system.nim:2527`) is
`cstderr.rawWrite(msg); cstderr.rawWrite("\n"); quit(code)` — the message goes
to **stderr**, help included, and always with a trailing newline. That is what
the library path has to reproduce byte for byte.

The process epilogue (237-240) is `handleCmdLine()`, then `storeFlush()` and
`dumpVfsProfile("lengc")`. Every `quit` above skips it, because `quit` does not
return.

`generateTimed` (56-63) is A1a's ledger hook: one `initPhaseTimer` and one
`noteProduce` around the whole `generateCode` call, because load, parse,
serialize and write were not separable from it. That is the seam A2a opens.

## 2. `generateCode` (`src/lengc/codegen.nim:837`)

```nim
proc generateCode*(s: var State, inp, outp: string; flags: set[GenFlag])
```

The body is already buffer-shaped; only its first and last lines touch files.

- `load(inp)` (838) is the only input read.
- `initGeneratedCode(m, flags, s.bits)` (840), `traverseCode` (844),
  `traverseTypes`/`generateTypes` (848-851) are the translation. `c.code` is
  moved out twice: once as the module body, once as the type declarations.
- `var f = CppFile()` (854): `CppFile` is `object; buf: string`
  (150-152), and `write`/`writeTokenSeq` only ever do `f.buf.add`. **The whole
  translation unit is a string in memory before anything is written.**
- `vfsWrite outp, f.buf` (880), guarded by
  `if vfsExists(outp) and vfsRead(outp) == f.buf` so an unchanged output keeps
  its mtime for the incremental build.
- The one side output is the header: when `c.headerFile.len > 0`, the tokens
  are concatenated into `hbuf` and written to `outp.changeFileExt(".h")`
  (882-887). There is no manifest, no `.deps`, no index.

`State` (`noptions.nim:34`) is `config*: ConfigRef; bits*: int`; `ConfigRef` is
an acyclic ref with `cCompiler`, `backend`, `options`, `optimizeLevel`,
`nifcacheDir`, `outputFile`, `appType`. `GenFlag` is
`gfMainModule, gfHasError, gfInCallImportC, gfInFlexArray`.

`error`/`errorAt` (`codegen.nim:193`, `211`) print to **stdout** and `quit 1`.
They are `{.noreturn.}` and are called from several hundred sites across
`codegen.nim`, `gentypes.nim`, `genexprs.nim` and `genstmts.nim`. Turning those
into returned errors is a rewrite of the whole backend, not a driver change;
see "Not done here" below.

The LLVM path (`llvmcodegen.generateLLVMCode`, `llvmcodegen.nim:964-970`) has
the same shape: `serializeModule` produces a string, `vfsWrite outp, llText`
writes it.

## 3. Module loading (`src/lengc/nifmodules.nim`)

`load*(filename): MainModule` (320) does four things in one proc:

1. `bif.isBifFile(filename)` (327) sniffs the format.
2. either `bif.load(filename)` (mmap, own fresh pools) or
   `rd.open(filename)` + `rd.processDirectives` + `nifcoreparse.parse` into a
   `TokenBuf` seeded with `createLengTagPool()` (330-341).
3. `densify` (342-357) copies that buffer into `result.src`, stamping every
   head token with its effective line info.
4. `detectToplevelDecls` fills `defs`/`types` for the module's own decls.

Foreign modules are lazy and path-based: `NifProgram.mods:
Table[string, ForeignModule]` keyed by **bare module suffix**, filled by
`loadForeign` (69), `canLoadForeign` (156) and `getDeclOrNil` (170) from
`foreignmodules.openForeignModule($c.prog.scheme)`, where `prog.scheme` is the
input's `SplittedModulePath` with `.name` swapped for the wanted suffix. So the
directory and extension of the *input path* decide where a foreign module is
looked for — which is why the buffer entry point still takes a logical path.

`foreignmodules.openForeignModule` (`src/lib/foreignmodules.nim:71`) is
path-only. `nifreader.openFromBuffer(buf, thisModule)` (`nifreader.nim:580`)
and `readEmbeddedIndex` (`foreignmodules.nim:42`) are both exported, so a
buffer-backed `ForeignModule` can be assembled from `src/lengc` without
touching `src/lib`. `bif.isBifFile` (`bif.nim:231`) opens the file with the raw
`syncio` API and bypasses every VFS relay; a buffer entry point sniffs the
buffer instead.

## 4. Options (`src/lengc/noptions.nim`, 64 lines)

No state at all: enums, `ConfigRef`, `State`, `ActionTable`,
`initActionTable`, two templates and `ExtAction`. Threaded by `var` from
`handleCmdLine` down to `generateCode`.

## 5. Module-level mutable state in `src/lengc/**`

`grep -rnE '^var( |$)' src/lengc/` — four declarations, all of them in
`shoggoth/`, none of them reachable from the `lengc` binary:

| file:line | declaration | reachable from `lengc`? | what a second run would do |
|---|---|---|---|
| `shoggoth/tracer_tmp.nim:33` | `var wantedSubstr = ""` | no (own `main`) | reassigned at the top of its own `main`, so it self-resets |
| `shoggoth/optfuzz.nim:72-74` | `var totalPasses/totalCrashes/totalMalformed = 0` | no (own `main`) | the fuzz summary would report both runs' counts as one |
| `shoggoth/cse.nim:146-149` | ten `g*` counters, `when defined(cseSummaryStats)` | no | the `-d:cseSummaryStats` summary would accumulate |

`{.global.}` has zero hits in the tree. `shoggoth/optdriver.nim:39`'s
`let disabledPasses` is an env snapshot taken at module init — immutable, but
it means `SHOGGOTH_DISABLE` is read once per process, not once per run.

Everything that *looks* like per-run state in the C and LLVM back ends is a
field of a per-call object built fresh by `initGeneratedCode` /
`initLLVMCode`: the temp counter (`CurrentProc.nextTemp`), the label and
string-literal counters (`LLVMCode`), the token `BiTable`, `generatedTypes`,
`requestedSyms`, `includedHeaders`, `fileIds`. `mangler.nim` is pure string
transformation with no counter at all, and `createLengTagPool()`
(`nifcdecl.nim:29`) builds a fresh pool per call.

**So lengc's own code is already re-entrant.** `resetLengcGlobals()` exists to
say that in one place, to be the hook `JIT_IMPL.md` A2b calls before every
in-process lengc node, and to make it a visible diff if someone later adds a
global.

### The globals that do matter are shared-library ones

| file:line | declaration | who owns the reset |
|---|---|---|
| `src/lib/nifcore.nim:444` | `fallbackPool*`, `fallbackTags*` | A2a-front `resetFrontendGlobals` |
| `src/lib/nifpools.nim` | `pool`, `globalTags` | A2a-front `resetFrontendGlobals` |
| `src/lib/vfs.nim:247-266` | the seven relays | the artifact store installs/uninstalls them; process policy, not per-run |
| `src/lib/artifactstore.nim:207` | `var store: ArtifactStore` | deliberately **not** reset per phase: it is the cross-phase cache A2b exists to exploit. `uninstallArtifactStore()` is the process-level teardown |
| `src/lib/artifactstore.nim:600` | `var request: StoreRequest` | genuine per-run CLI state, see below |
| `src/lib/toolhash.nim:34` | `var cachedToolhash` | process-lifetime by design (one `stat` per process) |

`resetLengcGlobals()` therefore documents a dependency rather than reaching
into `src/lib`: a caller that runs several tools in one process calls
`resetFrontendGlobals()` (A2a-front) as well.

## 6. Shared-library changes wanted (not made here — other agents own the files)

1. `src/lib/foreignmodules.nim`: an `openForeignModuleFromBuffer(content,
   module): ForeignModule` next to `openForeignModule(path)`. Until it exists
   `src/lengc/nifmodules.nim` carries a short local twin built from the
   already-exported `nifreader.openFromBuffer` + `readEmbeddedIndex`.
2. `src/lib/bif.nim`: `isBifFile` opens the file with raw `syncio` and bypasses
   the VFS relays, so a store-resident input cannot be sniffed. Wanted: an
   `isBifContent(s: string): bool` over bytes (the magic is the first
   `MagicLen` bytes), which is also what the buffer entry point needs. lengc
   carries a local `looksLikeBif(content)` meanwhile.
3. `src/lib/artifactstore.nim`: `resetStoreRequest*()` to clear
   `var request: StoreRequest`. Today a second `runLengc` in one process
   inherits the first run's `--vfs`/`--vfs-budget`. Note that the policy is
   also exported to the environment by `applyRequestedStore`, so clearing the
   request alone does not fully undo it — the environment variable is the
   documented cross-process channel and is deliberately sticky.

## 7. Not done here

- `codegen.error`/`errorAt` and the other 12 `quit` sites in the lengc library
  (`leng_model.nim:17,26`, `genexprs.nim:321`, `nifmodules.nim:336,337`,
  `llvmcodegen.nim:142,154,166,175`, `noptions.nim:61`) still end the process.
  They are the "this NIF is malformed" diagnostics, they are `{.noreturn.}`,
  and the call sites number in the hundreds. Making the backend return errors
  is its own phase; A2a converts the *driver's* exits, which is what
  `runLengc(args): int` needs to be callable.
- One deliberate deviation from today's process behaviour: the `isMainModule`
  shell runs `storeFlush()`/`dumpVfsProfile("lengc")` whenever `runLengc`
  returns 0, so `--help` and `--version` now reach the epilogue that `quit`
  used to skip. Both are no-ops there (the store is never installed before the
  option loop ends, and `dumpVfsProfile` only prints under `-d:vfsProfile`).

## 8. `PhaseTimer` seams (`src/lib/ledger.nim:542-598`)

`initPhaseTimer(dir, phase, module)` starts the mark; `mark`, `noteLoad`,
`noteParse`, `noteProduce`, `noteSerialize`, `noteWrite`, `noteBytes`,
`noteOutput`, `setModule`, `finish`. A1a could only fill `produce`. With the
split of section 2 the path-based wrapper gets all five:

- `noteLoad` — reading the input's bytes.
- `noteParse` — `nifcoreparse.parse` plus `densify` plus
  `detectToplevelDecls`.
- `noteProduce` — `traverseCode` + `traverseTypes` + `generateTypes`.
- `noteSerialize` — rendering the token sequences into the `.c` string.
- `noteWrite` — the `vfsExists`/`vfsRead` compare and the `vfsWrite`.
