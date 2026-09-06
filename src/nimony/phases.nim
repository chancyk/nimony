#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The phase registry and the in-process scheduling rule (JIT.md 6.1-6.2,
## JIT_IMPL.md A2b).
##
## A DAG node names a phase. A phase this module has registered can be run as
## a proc call in this process; everything else -- `cc`, `link`, `arkham`,
## `nifasm`, `niflink`, `ithaqua`, `dagon`, plugins, `{.build.}` tools -- is
## absent from the registry and therefore spawns, which is both the safe
## default and the documented contract for the plugin file protocol.
##
## The scheduler is the rule of JIT.md 6.2 and nothing more:
##
## ```
## if the phase is not registered:              spawn
## elif estimated produce < spawnCost * k:      in-process     (k = 3)
## elif ready nodes at this depth < cores:      in-process
## else:                                        spill inputs, spawn
## ```
##
## In-process nodes run **sequentially**, each preceded by a full reset of the
## globals the frontend shares (`semmain.resetFrontendGlobals`) plus the
## phase's own reset proc. Turning those globals into a context object is what
## would buy threads, and JIT.md 6.1 defers it until a ledger shows a workload
## where in-process threads would beat process fan-out.
##
## What still ends the process: a registered phase that hits one of its own
## `quit` sites. `notes/a2b.md` §3.1 lists them; they are all "the previous
## phase of this same build produced something the next one cannot read", i.e.
## a compiler bug rather than a user input, and turning ~200 `{.noreturn.}`
## call sites into an error channel is a phase of its own. What this module
## *does* contain is a `try`/`except` around every call, so an exception --
## as opposed to a `quit` -- becomes a failed node with its message instead of
## an unwound compiler.

import std / [os, cpuinfo, strutils, syncio]
import ".." / nifmake / dag
import ".." / lib / [ledger, artifactstore]
import semmain
import nimsem
import ".." / hexer / hexer
import ".." / lengc / lengc

# Nifler is NOT here, and it is the one phase of the frontend that still costs
# a process. Three reasons, in the order they were discovered, each on its own
# sufficient:
#
# 1. **A module-name collision that silently breaks the link.** Nifler parses
#    Nim with the compiler's own parser, so linking it needs
#    `--path:$nim/compiler` — which puts `compiler/platform.nim` in the same
#    module graph as `src/lib/platform.nim`. Nim names an object file after
#    the module's basename, so the two share `@pplatform.nim.c.o`, one
#    overwrites the other, and the link fails on `CPU`/`OS` referenced from
#    `nifconfig` and `deps`. Which of the two survives is a build-order
#    accident, which is worse than the failure.
# 2. **The import is not the parser, it is the compiler.**
#    `nifler/configcmd.nim` reaches `compiler/commands`, `nimconf`,
#    `cmdlinehelper` and from there `cgen`, `jsgen`, `vm`, `docgen`,
#    `sem` — nimony would contain a second, whole Nim compiler.
# 3. **`hastur boot` compiles nimony with nimony**, which cannot compile the
#    Nim compiler at all, so the phase would have to be `when`-gated out of
#    the booted compiler anyway and the two builds would schedule differently.
#
# The cost is one process per changed module: for a one-line edit of a
# one-module program the frontend spawns nifler and runs everything else in
# this process. Getting to zero needs `src/lib/platform.nim` renamed (or
# nifler's parser vendored the way `nimparser/parser.nim` already is), which
# is a change to files this phase does not own.

const
  DefaultInprocK* = 3
    ## JIT.md 6.2's `k`: how many spawn costs a phase may be worth before the
    ## fan-out is preferred to a call.
  MinSpawnCostNs* = 1_000_000'i64
    ## A floor under the ledger's spawn estimate. A key whose spawn average is
    ## still 0 has never been observed rather than being free, and
    ## `defaultSample` already says 3 ms; this guards the arithmetic against a
    ## ledger that recorded a suspiciously fast one.

type
  PhaseRunProc* = proc (argv: seq[string]): int {.nimcall.}
    ## `argv` is what `commandLineParams()` would have returned inside the
    ## tool -- no program path -- and the result is the exit code the process
    ## would have had. That is the shape A2a gave all four `run*` procs.
  PhaseResetProc* = proc () {.nimcall.}

  PhaseEntry* = object
    name*: string          ## the `cmd` name in the DAG: `nifler`, `dceEmit`, …
    run*: PhaseRunProc
    reset*: PhaseResetProc

  PhaseRegistry* = object
    ## Deliberately a seq and a linear scan: there are at most seven entries
    ## and the lookup happens once per stale node.
    entries*: seq[PhaseEntry]

  SpawnMode* = enum
    smAuto,    ## the rule of JIT.md 6.2 decides per node
    smAlways   ## every node spawns; the store stays, so this isolates
               ## scheduler bugs from store bugs

  PhaseSchedule* = object
    ## Everything the relay needs, in one object so that the only ambient
    ## state in this module is the single instance of it the `nimcall` relay
    ## has to reach.
    registry*: PhaseRegistry
    costs*: Ledger
    mode*: SpawnMode
    k*: int
    cores*: int
    inproc*: int      ## nodes run without a process, this process's lifetime
    spawned*: int     ## nodes handed back to the DAG to spawn
    active*: bool

# --- the registry ----------------------------------------------------------

proc registerPhase*(reg: var PhaseRegistry; name: string;
                    run: PhaseRunProc; reset: PhaseResetProc) =
  ## Register `name` as runnable in-process. Re-registering a name replaces
  ## it, which is what a test that swaps a phase for a stub needs.
  for i in 0 ..< reg.entries.len:
    if reg.entries[i].name == name:
      reg.entries[i].run = run
      reg.entries[i].reset = reset
      return
  reg.entries.add PhaseEntry(name: name, run: run, reset: reset)

proc findPhase*(reg: PhaseRegistry; name: string): int =
  ## Index of `name`, or -1.
  result = -1
  for i in 0 ..< reg.entries.len:
    if reg.entries[i].name == name: return i

proc resetNothing() {.nimcall.} =
  ## For a phase whose tool owns no state of its own beyond what
  ## `resetFrontendGlobals` already clears. `lengc.resetLengcGlobals` is empty
  ## for exactly that reason and says so at length; naming this here keeps the
  ## registration honest about which reset actually does work.
  discard

proc runHexerPhase(argv: seq[string]): int {.nimcall.} = runHexer(argv)
proc runLengcPhase(argv: seq[string]): int {.nimcall.} = runLengc(argv)
proc runNimsemPhase(argv: seq[string]): int {.nimcall.} = runNimsem(argv)
proc resetHexerPhase() {.nimcall.} = resetHexerGlobals()
proc resetLengcPhase() {.nimcall.} = resetLengcGlobals()

proc registerBuiltinPhases*(reg: var PhaseRegistry) =
  ## The phases of `src/nimony`, `src/hexer` and `src/lengc`.
  ##
  ## The names are the `cmd` names `deps.nim` emits, not tool names: one
  ## binary can appear under several of them (`hexer` is `hexer c`, `dce` is
  ## `hexer d`, `dceLive` is `hexer dl`, `dceEmit` is `hexer de`) and the
  ## action word is already the first element of the node's argv, so one
  ## registration per DAG command is all that is needed.
  ##
  ## Everything a build can name and this list does not -- `nifler` (see the
  ## comment block at the top of this module), `cc`, `link`, `nifasmObj`,
  ## `arkham`, `ithaqua`, `optimize`, `dagon`, `doclink`, `idetools`,
  ## `pluginbuild`, every `{.plugin.}` and every `{.build.}` tool -- spawns.
  ## That is the safe direction: a phase nobody registered costs a process,
  ## while a phase registered by mistake would run foreign code in the
  ## compiler's address space.
  registerPhase(reg, "nimsem", runNimsemPhase, resetNothing)
  registerPhase(reg, "hexer", runHexerPhase, resetHexerPhase)
  registerPhase(reg, "dce", runHexerPhase, resetHexerPhase)
  registerPhase(reg, "dceLive", runHexerPhase, resetHexerPhase)
  registerPhase(reg, "dceEmit", runHexerPhase, resetHexerPhase)
  registerPhase(reg, "lengc", runLengcPhase, resetLengcPhase)

# --- the rule --------------------------------------------------------------

proc moduleOfNode*(req: RunNodeRequest): string =
  ## The ledger's module key for a node: the suffix of its first output, which
  ## is what the tool inside also keyed its own sample with. A node with no
  ## output is a whole-program node and keys on the empty string, exactly as
  ## `nifmake`'s own `ledgerModuleOf` does (A1d).
  if req.outputs.len == 0: "" else: moduleSuffixOf(req.outputs[0])

proc wantsInproc*(s: PhaseSchedule; req: RunNodeRequest): bool =
  ## JIT.md 6.2, with nothing else in it. Split out from the relay so it can
  ## be reasoned about (and tested) without a build graph around it.
  if s.mode == smAlways: return false
  if findPhase(s.registry, req.name) < 0: return false
  # An `.args` file contributed tokens to this command. `expandCommandArgs`
  # inserts those verbatim because nifmake never split them into words, so the
  # argv is not faithful and the node has to reach a real shell.
  if req.rawArgs: return false
  if req.argv.len == 0: return false

  let key = LedgerKey(phase: req.name, module: moduleOfNode(req))
  # An empty toolhash asks about the phase regardless of which binary measured
  # it: the scheduler is weighing somebody else's tool, and stamping the query
  # with nimony's own hash would filter every entry out (`ledger.stampMatches`).
  let est = estimate(s.costs, key, "")
  var spawnCost = est.spawnNs
  if spawnCost < MinSpawnCostNs: spawnCost = MinSpawnCostNs
  if est.produceNs < spawnCost * s.k: return true
  # Cheap enough is settled; what is left is whether the fan-out would have
  # anything to fan out to.
  result = req.readyAtDepth < s.cores

# --- the relay -------------------------------------------------------------

var gSchedule = PhaseSchedule(k: DefaultInprocK, cores: 1)
  ## The one piece of ambient state in this module, and the registry JIT_IMPL's
  ## style rule allows: `dag.runNodeRelay` is a `{.nimcall.}` proc with no
  ## context parameter -- the shape `src/lib/vfs.nim` established for every
  ## relay in this toolchain -- so the schedule has to be reachable without
  ## one. Everything else here is threaded through `PhaseSchedule` explicitly.

proc runPhaseInproc(entry: PhaseEntry; argv: seq[string]): tuple[code: int, msg: string] =
  ## One in-process node: reset, run, report. `argv` already has the tool path
  ## stripped.
  ##
  ## `resetFrontendGlobals` first and unconditionally, because it is the
  ## superset: it clears `nifpools.pool`/`globalTags`, `programs.prog`,
  ## `identstyle`'s style tables and the file-line cache, and a process that
  ## runs sem after hexer needs all four (hexer's own reset covers only the
  ## first two and says so). The phase's own reset then adds whatever is
  ## private to it.
  resetFrontendGlobals()
  entry.reset()
  try:
    result = (entry.run(argv), "")
  except CatchableError as e:
    result = (1, e.msg)
  except Defect as e:
    result = (1, e.msg)

proc inprocRelay(req: RunNodeRequest): RunNodeStatus {.nimcall.} =
  if not gSchedule.active: return RunSpawn
  if not wantsInproc(gSchedule, req):
    # Hand the node's inputs a disk copy before the process that will read
    # them off the disk starts. A no-op today -- every artifact is written
    # through (`notes/a1b.md` §3) -- and the line that stops being a no-op the
    # moment a suffix moves into `addEphemeralSuffix`.
    spillAll(req.inputs)
    inc gSchedule.spawned
    return RunSpawn
  let idx = findPhase(gSchedule.registry, req.name)
  let (code, msg) = runPhaseInproc(gSchedule.registry.entries[idx], req.argv[1 .. ^1])
  inc gSchedule.inproc
  if code == 0:
    result = RunHandledOk
  else:
    if msg.len > 0: stderr.writeLine "nimony: " & req.name & ": " & msg
    result = RunHandledFailed

# --- installation ----------------------------------------------------------

proc envInt(name: string; fallback: int): int =
  let v = getEnv(name)
  if v.len == 0: return fallback
  try:
    result = parseInt(v)
    if result < 1: result = fallback
  except ValueError:
    result = fallback

proc spawnModeFromEnv*(fallback: SpawnMode): SpawnMode =
  ## `NIMONY_SPAWN` is how a parent hands the mode to `nimony s` and to any
  ## other child, for the same reason A1b put `--vfs` in the environment: a
  ## flag spliced into `c.commandLineArgs` lands in the `.build.nif`, and two
  ## modes would then emit different build files -- which is exactly what this
  ## phase's gate forbids the tests from tolerating.
  case getEnv("NIMONY_SPAWN").normalize
  of "always": smAlways
  of "auto": smAuto
  else: fallback

proc inprocKFromEnv*(fallback: int): int = envInt("NIMONY_INPROC_K", fallback)

proc installPhaseRelay*(mode: SpawnMode; nimcache: string; k = DefaultInprocK) =
  ## Put the scheduler in front of the DAG. Called once, from `nimony`'s
  ## `main`; `smAlways` installs nothing at all, so the escape hatch is
  ## literally the process tree of the release before this one.
  if mode == smAlways:
    gSchedule.active = false
    return
  gSchedule = PhaseSchedule(
    registry: PhaseRegistry(entries: @[]),
    costs: openLedger(nimcache / "ledger.nif"),
    mode: mode, k: k, cores: countProcessors(),
    inproc: 0, spawned: 0, active: true)
  if gSchedule.cores < 1: gSchedule.cores = 1
  registerBuiltinPhases(gSchedule.registry)
  runNodeRelay = inprocRelay

proc phaseRelayActive*(): bool = gSchedule.active
proc inprocCount*(): int = gSchedule.inproc
