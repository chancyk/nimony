# Phase A2b — research notes

Written before the implementation, per `JIT_IMPL.md` "Execution rules for
agents" rule 3. Worktree branch `jit/a2b`, forked from `fast-devloop`
(`ae5f8d51`, i.e. with all of wave 1, wave 2 and A2a in).

---

## 1. `src/nifmake/nifmake.nim` as it stands (981 lines)

### 1.1 Types

```nim
NodeState = enum nsUnvisited, nsInStack, nsVisited     # NOT exported
Command* = object
  name*: string
  tokens*: TokenBuf     ## the `(cmd …)` template
  ext*: string          ## `argsext`, default ".args"
Node* = object
  cmdIdx*: int          ## index into Dag.commands
  inputs*, outputs*, args*: seq[string]
  deps*: seq[int]       ## node ids
  state*: NodeState
  depth*: int
Dag* = object
  nodes*: seq[Node]
  nameToId*: Table[string, int]   ## output path -> producing node
  maxDepth*: int
  commands*: seq[Command]
  baseDir*: string      ## the `.args` search root (`--base`)
  nimcache*: string     ## `parentDir` of the build file; the ledger target
CliCommand = enum cmdRun, cmdMakefile, cmdHelp, cmdVersion   # CLI only
CliOption = enum Parallel, Force, Rerun, Verbose, Profile, Report, Progress
ProfileData* = object          ## fields all private
  parseTime, dagSetupTime: float
  cmdTime: Table[string, tuple[sec: float, count: int]]
  execWallTime: float
```

plus A1b's relay seam (`RunNodeStatus*`, `RunNodeRequest*`) and the CLI-only
`CmdStatus` / `Progressor`.

### 1.2 The build-file grammar, from a real `hello.nim` build

`(cmd :<name> "<tool>" "<flag>"… (args) (input a b) (output a b))` declares a
template; `(do <name> (args "…") (input "path")… (output "path")…)` is one
node. Dependencies are **structural**: `addNode` indexes every output in
`nameToId`, and `findDependencies` links a node to whoever produces one of its
inputs. Verified against `/tmp/a2b_probe/nc/hel16t2fh{,.final}.build.nif`:

| DAG cmd | argv the node expands to (after the tool path) |
|---|---|
| `nifler` | `--portablePaths --deps parse <src.nim> <out.p.nif>` |
| `nimsem` | `--base:<d> --nimcache:<d> --define:…  m [--isMain\|--isSystem] <mod.p.nif> [cyclic…]` |
| `hexer` | `c --bits:64 --cpu:le --os:MacOSX --flags:br [--isMain --app:console --outdir:<d>] <mod.s.nif>` |
| `dce` | `d --bits:64 --cpu:le <all inputs>` |
| `dceLive` | `dl --bits:64 --cpu:le <every .dce.nif> <main.live.nif>` |
| `dceEmit` | `de --bits:64 --cpu:le --outdir:<d> <mod.x.nif> <main.live.nif>` |
| `lengc` | `c --compileOnly --bits:64 --nimcache:<d> [--isMain] <mod.c.nif>` |
| `cc` | `-c -Wno-attributes -O1 -I<root> <mod.c> -o <mod.o>` |
| `link` | `<main.linkmanifest.nif> <exe>` (niflink) |

Other command names that can appear: `dagon`, `doclink` (doc backend),
`ithaqua`, `arkham`, `nifasmObj` (native), `optimize` (shoggoth), `idetools`,
`pluginbuild`, and one command per `{.plugin.}` / `{.build.}` tool.

### 1.3 `needsRebuild`

No outputs → always run. Any missing output → run. Otherwise the **freshest**
output mtime is the reference (max, not min, because tools write some outputs
`OnlyIfChanged`), and any existing input newer than it makes the node stale. A
missing input is ignored. Everything goes through `vfsExists`/`vfsMtime`, so
A1b's store already sees it.

### 1.4 `topologicalSort` and the two `runDag` paths

`visit` is a DFS post-order that also assigns `node.depth = 1 + max(dep
depths)` and `quit`s on a cycle. The result is then re-sorted by depth, so the
returned `seq[int]` is **flat but depth-contiguous**. `runDag`:

* `Parallel in opt`: an outer loop takes one contiguous depth at a time,
  collects every stale node's expanded command into `commands`, and hands the
  batch to `osproc.execProcesses` with `beforeRunEvent`/`afterRunEvent`.
* otherwise: one `for nodeId in sortedNodes` loop calling `executeCommand`
  (`execShellCmd`).

A1b's `offerNode` sits in both, immediately after `expandCommand`. It
short-circuits to `RunSpawn` while `runNodeRelay == spawnEverything`, so the
default costs nothing. `RunHandledOk` counts as an executed command
(`recordCmdTime(cmdName, 0.0)`) and never enters the `execProcesses` batch.

### 1.5 `expandCommand`

Walks `cmd.tokens`. The first `StrLit` is the tool, resolved by `findTool` and
`quoteShell`ed; it also triggers the `.args` file lookup
(`findArgs(baseDir, extractArgsKey(tool) & cmd.ext)`), whose tokens are
inserted **unquoted** at the `(args)` position after the node's own args.
`(input …)`/`(output …)` take an optional string prefix, one or two int
indices (negative = from the end) and an optional suffix, and emit
`prefix & quoteShell(suffix & filename)` — the prefix is *not* quoted. Every
other token is an error.

The consequence for A2b: the expansion is a **shell string**, not an argv.
See §4.1.

### 1.6 `--report` / `--profile` / `--progress`

`printReport` writes one stdout line: `nifmake-report` then, sorted by command
name, ` <cmd>=<count>`, then ` total=<N>`, then `\n`. `printProfile` writes a
block on stderr. `Progressor.draw` writes `\r[NNN%] <label>\e[K\r`.

`src/hastur/incrementaltests.nim` parses the report by splitting the line on
spaces and reading every `k=v` pair, so **appending** a field is safe.

### 1.7 A1d's `SpawnLog`

`runDag` keeps a local `SpawnLog`; every node that actually reached a process
(`RunSpawn` only) appends `(cmdName, moduleSuffixOf(outputs[0]), wallNs)`, and
`consolidate(dag.nimcache, spawns)` folds it into `<nimcache>/ledger.nif` once
at the end, skipped entirely when nothing spawned.

### 1.8 Process-global state

Only two module-level `var`s: `runNodeRelay*` (A1b's seam) and `gMaxJobs`
(the `-j:N` cap, written by the option parser, read by `runDag`). `gMaxJobs`
is exactly the kind of ambient state a library caller cannot set, so A2b turns
it into a `runDag` parameter and the CLI keeps it as a local.

Everything else nifmake touches is shared with the rest of the toolchain:
`nifpools.pool`/`globalTags`, the seven `vfs` relays, `artifactstore`'s store.

### 1.9 `quit` sites in the parse/run path

`expandCommand` (undeclared command), `topologicalSort` (cycle),
`parseCommandDefinition` ×3, `parseDoRule` ×3, `parseNifFile` ×3. All of them
are "this build file is malformed", which for an in-process caller means
"nimony emitted a build file it cannot itself read" — a compiler bug, not a
user input. They stay `quit`s.

---

## 2. How nimony drives nifmake today

`deps.buildGraph` (`deps.nim:2269`) builds

```nim
let nifmakeBase = quoteShell(nifmake) &
  (if forceRebuild: " --force" else: "") &
  (if Profile in flags: " --profile" else: "") &
  (if Report in flags: " --report" else: "") &
  " --base:" & quoteShell(config.baseDir)
let nifmakeCommand  = nifmakeBase & " -j run "
let frontendCommand = nifmakeBase & (if configChanged: " --rerun" else: "") & " -j run "
```

and `exec`s it at four sites: the frontend graph (`:2310`), the doc backend
(`:2329`), P0b's `fpAnalysis` graph (`:2357`) and the codegen/backend graph
(`:2385`). `progArg(flags, lo, hi)` adds `--progress:lo:hi` unless `SilentMake`
or `Report`. Note nimony passes a **bare `-j`** — the `-j:N` cap exists in
nifmake but nothing ever supplies a value.

Two graphs per ordinary build (frontend 0–50 %, backend 50–100 %); `DoCheck`
skips the second; `DoDoc` substitutes the doc graph; a CTFE sub-compile of a
`.p.nif` project with the object cache runs three (`fpAnalysis`, then
`fpCodegen`) and B2's `--ctfe-analysis-only` returns after the first.

`--vfs` is deliberately *not* in the build file (A1b): it rides the
`NIMONY_VFS` environment variable so two modes emit byte-identical
`*.build.nif`. A2b needs the same discipline for its own flags.

---

## 3. The A2a entry points

| tool | run proc | reset proc |
|---|---|---|
| nifler | `nifler.runNifler(argv: seq[string]): int` | `nifler.resetNiflerGlobals()` (empty; documented why) |
| nimsem | `nimsem.runNimsem(argv: seq[string]): int` | `semmain.resetFrontendGlobals()` = `resetPools` + `resetProgram` + `resetStyleTables` + `resetFileLineCache` |
| hexer | `hexer.runHexer(args: seq[string]): int` | `hexer.resetHexerGlobals()` = `resetProgram` + `resetPools` + `resetInlinerStats` |
| lengc | `lengc.runLengc(args: seq[string]): int` | `lengc.resetLengcGlobals()` (empty; documented why) |

All four take **what `commandLineParams()` returns** — no program path at
index 0. All four return the exit code instead of quitting.

`resetHexerGlobals` is a strict subset of `resetFrontendGlobals` plus
`resetInlinerStats`, so a process that mixes sem and hexer has to call
`resetFrontendGlobals()` (identstyle and the file-line cache are sem's and
hexer's reset does not touch them). A2b therefore calls
`resetFrontendGlobals()` before **every** in-process node and then the phase's
own reset on top.

### 3.1 What still `quit`s inside a registered phase

| tool | site | what it means |
|---|---|---|
| nimsem, hexer, lengc | `nifreader.open` — `quit "[Error] cannot open: " & filename` (`src/lib/nifreader.nim:574`, and lengc's own copy at `nifmodules.nim:401`) | an input the DAG promised is gone |
| hexer | `EContext.error` / `errorAt`, `{.noreturn.}` (`src/hexer/hexer_context.nim:94-107`), ~200 call sites | malformed Leng IR |
| hexer | `duplifier.nim:1540,1572,1606` | move-type diagnostics |
| lengc | `codegen.error`/`errorAt`, `{.noreturn.}` (`src/lengc/codegen.nim:193-220`) | malformed `.c.nif` |
| nimsem | `cli.parseCommonOption` for `--help`/`--version` (`cli.nim:54,56`) | never passed by the DAG |
| nifler | none on the `runNifler` path | |

These are all "the previous phase in this same build produced something the
next phase cannot read", i.e. a compiler bug rather than a user input, which
is why A2b keeps them: turning ~200 `noreturn` call sites into an error
channel is its own phase. What A2b *does* do is wrap each `run*` call in a
`try/except CatchableError/Defect` so an exception (as opposed to a `quit`)
becomes a failed node with a message instead of an unwound compiler.

### 3.2 Linking all four into one binary

- No two of `nimony.nim`, `nimsem.nim`, `hexer.nim`, `lengc.nim`,
  `nifler.nim` import each other today; a combined driver is the first place
  their graphs meet.
- All five gate their process shell behind `when isMainModule`, so importing
  them runs nothing.
- There is exactly **one** `prog` (`programs.nim`) and one `pool`/`globalTags`
  (`nifpools.nim`), shared on purpose. No conflicting globals.
- `src/lib/compat2.nim` is `include`d by nifler, hexer and lengc, so each
  re-exports its own `getOrQuit*`/`path*`. Latent ambiguity: the *driver*
  module must not call either unqualified. `phases.nim` does not.
- **nifler is the one real obstacle.** It is built against Nim's own
  `compiler/parser.nim` (`src/nifler/nim.cfg`: `--path:"$nim"`,
  `--define:nimcore`, `--path:"$nim/compiler"`, plus `syncNimParser`'s pinned
  checkout). Two consequences:
  1. nimony's host-Nim build needs those three flags. Verified they suffice:
     a probe importing `nifler/bridge` and `nimony/deps` together compiles and
     links.
  2. `hastur boot` compiles nimony **with nimony**, and nimony cannot compile
     the Nim compiler's parser. So the nifler registration is gated
     `when not defined(nimony)`: a nimony-built nimony spawns nifler and is
     otherwise identical. `nimony` is always in `config.defines`
     (`nifconfig.nim:175`), which is what makes the gate work.

  nimsem, hexer and lengc have no such problem: nimsem and hexer are on the
  boot self-compile list already, and `bin/nimony c src/lengc/lengc.nim`
  succeeds (checked, exit 0).

---

## 4. The design A2b implements

### 4.1 `expandCommand` had to grow an argv

The relay is handed a shell string. Calling `runHexer` needs a `seq[string]`.
Shell-splitting the string back is fragile (quoting, `.args` files), so
`dag.nim` factors the walker into `expandCommandArgs`, which returns

```nim
CmdArg = object
  prefix: string   ## emitted verbatim (the `(input "-o:" …)` prefix)
  body: string     ## emitted `quoteShell`ed, unless `raw`
  raw: bool        ## a token from a `.args` file: emitted verbatim
```

`renderCommand` joins them exactly the way `expandCommand` did (the same
`addSpace` rule, the same `quoteShell` placement), so the spawned command line
is byte-identical; `argvOf` yields `prefix & body` per element. A node whose
expansion contains a `raw` element (i.e. an `.args` file matched) is never run
in-process — `.args` tokens are pre-split shell words and reconstructing their
argv is guesswork.

### 4.2 The registry (`src/nimony/phases.nim`)

```nim
PhaseRunProc*   = proc (argv: seq[string]): int {.nimcall.}
PhaseResetProc* = proc () {.nimcall.}
PhaseEntry* = object
  name*: string          ## the DAG `cmd` name
  argv0*: seq[string]    ## tokens the tool's own CLI needs but the DAG does not carry
  run*: PhaseRunProc
  reset*: PhaseResetProc
PhaseRegistry* = object
  entries*: seq[PhaseEntry]
```

`registerPhase(reg, name, run, reset)` appends; `findPhase(reg, name)` is a
linear scan over ≤ 7 entries. Built-ins: `nifler` (host-Nim builds only),
`nimsem`, `hexer`, `dce`, `dceLive`, `dceEmit`, `lengc`. Everything else —
`cc`, `link`, `arkham`, `nifasm`, `niflink`, `ithaqua`, `nifasmObj`,
`optimize`, `dagon`, `doclink`, `idetools`, `pluginbuild`, every plugin and
every `{.build.}` tool, `nim` — is simply absent and therefore spawns.

The argv handed to a `run*` proc is `argvOf(expansion)[1 .. ^1]`: the tool
path token is dropped, which is exactly `commandLineParams()`.

### 4.3 The rule (JIT.md 6.2)

For each stale node, in the order the DAG depth presents it:

```
if spawnMode == always                        -> spawn
elif phase not registered                     -> spawn
elif the expansion carries `.args` tokens     -> spawn
else:
  est   = ledger.estimate((phase, module)).produceNs
  spawn = ledger.estimate((phase, module)).spawnNs   (>= 1 ms floor, default 3 ms)
  if est < spawn * k          (k = 3, `--inproc-k:`) -> in-process
  elif readyAtDepth < countProcessors()              -> in-process
  else: artifactstore.spillAll(node.inputs); spawn
```

`readyAtDepth` is new information the relay needs, so `runDag`'s parallel path
was split into two passes over each depth: pass 1 runs `needsRebuild` and
collects the ids that will run (exactly the same set, the same number of
`needsRebuild` calls), pass 2 offers each of them with the count in hand. The
sequential path reports `readyAtDepth = 1`, which is the truth: nothing fans
out there.

In-process nodes run **sequentially** in DAG order, each preceded by
`resetFrontendGlobals()` and the phase's own reset. Spawned nodes of the same
depth still go to `execProcesses`, which A1b's tri-state already supports.

### 4.4 Where the driver lives, and what links what

`deps.nim` imports `nifmake/dag` only (which pulls in nothing new: the same
`src/lib` modules `deps.nim` already has). `deps.buildGraph`'s four `exec`
sites become `runBuildFile(...)`, which either spawns `nifmake` exactly as
today (`--spawn:always`) or parses the file and calls `dag.runDag` in this
process.

`nimony.nim` is the only binary that imports `phases.nim`, and it installs the
relay at startup. **nimsem does not**, so nimsem links no extra tools and
`hastur boot`'s nimsem stage is untouched. That also keeps A2c's job intact:
putting the CTFE graph in nimsem's own process is A2c's, not A2b's.

### 4.5 Flags, and why none of them is forwarded through the build file

Same reasoning as A1b's `--vfs`: anything in `c.commandLineArgs` is spliced
into the `.build.nif`, and two modes would then emit different bytes — which
is precisely what this phase's gate forbids the test from tolerating. So:

| flag | env for children | effect |
|---|---|---|
| `--spawn:always` \| `--spawn:auto` | `NIMONY_SPAWN` | `always` restores today's process tree exactly, `nifmake` spawn included |
| `--jobs:<n>` | `NIMONY_JOBS` | `1` runs the DAG sequentially; `n > 1` caps `execProcesses` |
| `--inproc-k:<n>` | `NIMONY_INPROC_K` | the `k` of the rule, default 3 |

`--vfs:disk` given **on the command line** implies `--spawn:always`
(`JIT_IMPL.md` A2b step 3, JIT.md 6.2 "`--vfs:disk` forces today's behaviour
entirely"). It is the explicit flag that implies it, not the resolved policy:
A1b left the default policy at `disk` until A2c flips it, so making the
*resolved* policy imply spawning would leave A2b dead code at its own default
and its gate unreachable. `NIMONY_VFS=disk` in the environment therefore does
not disable the in-process path — `bench/devloop_bench.sh` sets exactly that,
and it must measure the thing it is pointed at.

### 4.6 `--report` and `--profile`

`reportLine(profile)` returns the string `printReport` used to write, with
` inproc=<n>` appended after `total=`. The prefix is byte-identical and the
field parser in `incrementaltests.nim` picks the new field up for free.
`--profile` attributes an in-process node's wall time to its phase, which is
strictly more information than the `0.0` A1b's seam recorded.

The ledger keeps working unchanged: an in-process node's `produce` is written
by the tool's own `PhaseTimer` (the same code runs), and its `spawn` is
nothing at all, because `SpawnLog` only ever hears about `RunSpawn` nodes.

---

# Phase A2b — what was built

## The split

`src/nifmake/dag.nim` is the graph (parse, topo sort, staleness, `runDag`, the
Makefile writer, the relay seam); `nifmake.nim` is 184 lines of option parsing,
help text and two write calls. `hastur build nifmake` is unchanged and the
generated Makefile of a real hello-world build is byte-identical through both
graphs, which is the check that `expandCommand` survived being split into
`expandCommandArgs` + `renderCommand`.

Three things changed shape rather than only moving:

- **`runDag` takes `maxJobs` as a parameter.** It read a module-level
  `gMaxJobs` only the option parser could write; a second caller in one process
  would have inherited it.
- **`--report` and `--profile` are strings.** `reportLine` and `profileText`,
  written by whoever called; two programs emit those bytes now.
- **`Command.tokens: TokenBuf` became `slots: seq[CmdSlot]`.** This one is
  load-bearing rather than cosmetic: `input`/`output`/`args` are not master
  tags, so their `TagId`s belong to the `globalTags` that parsed this build
  file — and every in-process phase calls `resetPools()` on entry. A `Dag` that
  still needed the pool to read its own commands would decode garbage after the
  first in-process node. Holding strings and ints makes the graph independent
  of pool state.

## The registry, as implemented

| DAG `cmd` | in-process entry | reset |
|---|---|---|
| `nimsem` | `nimsem.runNimsem` | `semmain.resetFrontendGlobals` |
| `hexer` (`hexer c`) | `hexer.runHexer` | + `hexer.resetHexerGlobals` |
| `dce` (`hexer d`) | `hexer.runHexer` | + `hexer.resetHexerGlobals` |
| `dceLive` (`hexer dl`) | `hexer.runHexer` | + `hexer.resetHexerGlobals` |
| `dceEmit` (`hexer de`) | `hexer.runHexer` | + `hexer.resetHexerGlobals` |
| `lengc` | `lengc.runLengc` | + `lengc.resetLengcGlobals` (empty) |

`resetFrontendGlobals()` runs before **every** in-process node and the phase's
own reset on top of it: it is the superset (pools, `prog`, identstyle, the
file-line cache) and `resetHexerGlobals` covers only the first two.

Unregistered, and therefore spawned: `nifler`, `cc`, `link`, `nifasmObj`,
`arkham`, `ithaqua`, `optimize`, `dagon`, `doclink`, `idetools`,
`pluginbuild`, every `{.plugin.}` and every `{.build.}` tool.

### Why nifler is not on that list

Three findings, each sufficient on its own:

1. Linking it needs `--path:$nim/compiler`, which puts `compiler/platform.nim`
   and `src/lib/platform.nim` in one module graph. Nim names an object file
   after the module basename, so both are `@pplatform.nim.c.o`, one overwrites
   the other, and the link fails on `CPU`/`OS` referenced from `nifconfig` and
   `deps`. Which one survives is a build-order accident, which is worse than
   the failure.
2. `nifler/configcmd.nim` reaches `compiler/commands`, `nimconf`,
   `cmdlinehelper` and from there `cgen`, `jsgen`, `vm`, `docgen`, `sem`:
   nimony would contain a second, whole Nim compiler.
3. `hastur boot` compiles nimony with nimony, which cannot compile the Nim
   compiler at all.

Both (1) and (2) were reproduced, not reasoned about: the flags were added to
`buildNimony`, the compile succeeded through ~300 extra modules, and the link
failed on `_CPU__OOZlibZplatform_u747`. Getting nifler in-process needs
`src/lib/platform.nim` renamed, or nifler's parser vendored the way
`nimparser/parser.nim` already is — a change to files this phase does not own.

## The rule, as implemented

`phases.wantsInproc(schedule, request)` is the whole decision and takes no
build graph, so it reads as JIT.md 6.2 does:

```
if mode == smAlways                                     -> spawn
if the phase is not registered                          -> spawn
if the expansion carries `.args` tokens                 -> spawn
est   = estimate(ledger, (phase, module), "").produceNs
spawn = max(estimate(...).spawnNs, 1 ms)
if est < spawn * k        (k = 3, `--inproc-k:`)        -> in-process
else                                                    -> readyAtDepth < countProcessors()
```

Two details worth naming:

- **The toolhash is empty on purpose.** `ledger.stampMatches` documents the
  door: the scheduler is weighing somebody *else's* tool, and stamping the
  query with nimony's own hash would filter every entry out.
- **`readyAtDepth` is new information**, so `runDag`'s parallel path became two
  passes over each depth: pass 1 runs `needsRebuild` and collects the ids that
  will run, pass 2 offers each with the count in hand. The same set, the same
  number of `needsRebuild` calls. The sequential path reports 1, which is the
  truth there.

`--jobs:1` drops the batch and takes the sequential path; `--spawn:always`
installs no relay at all, so `deps.runMake` spawns `nifmake` and `nifmake`
spawns every node — the process tree of the release before this one. An
explicit `--vfs:disk` on the command line implies it.

## Where the driver lives

`deps.nim` imports `nifmake/dag` and nothing else new; `nimony.nim` is the only
binary that imports `phases.nim`. So **nimsem links no extra tools**, which
keeps `hastur boot`'s nimsem stage untouched and leaves A2c's job (the CTFE
graph inside nimsem's own process) intact.

nimony links nimsem, hexer and lengc: **2.91 MB -> 4.77 MB**, and its own
compile went from ~1.6 s to ~4.0 s.

## What is behind a define, and why

`hastur boot` compiles nimony with nimony, and `dag.nim` is not in nimony's
language yet. Boot stage 1 named four things:

- `osproc.execProcesses` with `beforeRunEvent`/`afterRunEvent` callbacks;
- `topologicalSort`'s comparison closure over `addr dag.nodes`;
- `strutils.align` (the progress bar) and `alignLeft` (`profileText`);
- `sequtils.foldl` (`profileText`'s totals).

So `deps.nim` and `nimony.nim` import the library and the scheduler under
`when not defined(nimony)`, and `deps.inProcessMakeAvailable()` answers `false`
in a booted compiler. It then spawns `nifmake` for every graph — the previous
release's behaviour exactly, and `nifmake` is a carry tool (host-Nim built at
every boot stage), so nothing is lost but the speed-up. `hastur boot` reaches a
byte-identical stage2 == stage3.

Two smaller consequences of the same gate: `makeJobs()` answers "all cores" in
a booted compiler (no environment API), and `--jobs`/`--spawn`/`--inproc-k` are
parsed and ignored there. `parseInt` + `except ValueError` also had to become a
hand-rolled digit scan, since `except ValueError` is not nimony's language
either.

## What still `quit`s in-process

Unchanged from §3.1, and now with a `try`/`except CatchableError`/`Defect`
around every `run*` call so an *exception* becomes a failed node with its
message. A `quit` still ends the compiler:

| where | what |
|---|---|
| `nifreader.open` (`src/lib/nifreader.nim:574`) and lengc's copy (`nifmodules.nim:401,388,389`) | an input the DAG promised is missing or malformed |
| `hexer_context.EContext.error`/`errorAt` (`:94-107`, `{.noreturn.}`, ~200 call sites) | malformed Leng IR |
| `hexer/duplifier.nim:1540,1572,1606` | move-type diagnostics |
| `lengc/codegen.error`/`errorAt` (`:193-220`, `{.noreturn.}`) plus `llvmcodegen.nim:142,154,166,175`, `leng_model.nim:17,26`, `genexprs.nim:321`, `noptions.nim:61` | malformed `.c.nif` |
| `cli.parseCommonOption` for `--help`/`--version` (`cli.nim:54,56`) | never passed by a DAG node |
| `dag.nim`'s own parse/expand/cycle quits | nimony emitted a build file it cannot read |

Every one of these is "the previous phase of this same build produced something
the next one cannot read", i.e. a compiler bug rather than a user input. In the
spawning arrangement the cost was one dead child and a `FAILURE:` line; now it
is the compiler. Turning ~200 `{.noreturn.}` call sites into an error channel
is a phase of its own.

## Tests

- `tests/incremental` runs the existing 15 + 2 phases three times: default,
  `--vfs:memory+spill`, and `--spawn:always`. The assertions are per phase and
  come out identical.
- `incrementalInprocTests` adds four phases: cold `inproc >= 5`; a one-line
  edit leaving the frontend graph with no spawned node but nifler and the
  backend graph with none but `cc`/`link`; byte identity of every `.nif`/`.c`
  between the scheduler and `--spawn:always` with each nimcache's own path
  normalised away (the ledger snapshot and `.ledger/` fragments excluded —
  they record *how* the build ran); and a `const` sub-compile leaving no
  `spawn` sample for `nimsem`/`hexer`/`dce*`/`lengc` in `<nimcache>/ledger.nif`
  while leaving one for `cc`/`link`, which is what proves the assertion is not
  passing on a build that never happened.
- `tests/ctfe_diff` gains a third mode pair, `--spawn:always` vs the default.
