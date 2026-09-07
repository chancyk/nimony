#       Nifmake tool
# (c) Copyright 2025 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The nifmake build graph, as a library.
##
## Nifmake is a make-like tool that Nimony uses to implement parallel and
## incremental compilation: it runs a dependency graph specified by a `.nif`
## file, or translates that file into a Makefile. Everything but the command
## line lives here; `nifmake.nim` is the CLI over it.
##
## The split exists because Nimony runs the same graph **in its own process**
## when the scheduler of `JIT.md` 6.2 says a node is not worth a process
## (`src/nimony/phases.nim`). Two rules keep that honest and are the reason
## several procs here look more awkward than a private helper would:
##
## * Nothing in this module holds state between calls. `runDag` takes its job
##   cap as a parameter rather than reading a global, so two callers in one
##   process cannot inherit each other's settings. The one exception is
##   `runNodeRelay`, which is a seam by construction (A1b) and documented as
##   such where it is declared.
## * `--report` and `--profile` are produced as *strings* (`reportLine`,
##   `profileText`) rather than written to a file handle, so the in-process
##   driver emits the same bytes on the same stream as the CLI does.

import std/[assertions, os, strutils, sequtils, tables, hashes, times, monotimes, syncio, osproc, algorithm, terminal]
import ".." / lib / [bitabs, nifreader, tooldirs, argsfinder, vfs, nifpools, ledger]

# Inspired by https://gittup.org/tup/build_system_rules_and_algorithms.pdf
#[
build_partial_DAG(DAG, change_list)
   foreach file_changed in change_list {
     add_node(DAG, file_changed)
   }

add_node(DAG, node)
  add node to DAG
  dependency_list = get_dependencies(node)
  foreach dependency d in dependency_list {
    if d is not in DAG { add_node(DAG, d) }
    add link (node -> d) to DAG
  }

update(DAG)
  file_list = topological_sort(DAG)
  foreach file in file_list {
    perform command to update file
  }

Example for a .nif file:

```nif
(stmts
  (cmd :nifler "nifler" (input) (output))
  (do nifler
    (input "a.nim")
    (output "a.p.nif")
  )
)
```

]#

type
  NodeState* = enum
    nsUnvisited
    nsInStack
    nsVisited

  CmdSlotKind* = enum
    csLiteral,   ## a `StrLit` of the `(cmd …)` template
    csArgs,      ## the `(args)` placeholder
    csInput,     ## an `(input [prefix] [a [b]] [suffix])` slot
    csOutput     ## the same over the node's outputs

  CmdSlot* = object
    ## One element of a `(cmd …)` template, decoded at parse time.
    ##
    ## Decoded, and not kept as the `TokenBuf` it used to be, because a
    ## `TagId` is only meaningful against the `globalTags` it was interned in
    ## and `input`/`output`/`args` are not master tags — their ids depend on
    ## the order this build file happened to mention them. A2b runs phases in
    ## the same process as the DAG, and every one of them calls `resetPools()`
    ## on entry (JIT.md 6.1), so a `Dag` that still needed the pool to read
    ## its own commands would decode garbage after the first in-process node.
    ## Holding strings and ints makes the DAG independent of pool state, which
    ## is the property the in-process scheduler needs and the CLI never
    ## noticed it had.
    kind*: CmdSlotKind
    text*: string           ## `csLiteral`: the argument
    prefix*, suffix*: string
    a*, b*: int             ## as written; negative counts from the end
    hasA*, hasB*: bool

  Command* = object
    name*: string
    slots*: seq[CmdSlot]
    ext*: string

  Node* = object
    cmdIdx*: int      # index into Dag.commands
    inputs*: seq[string]
    outputs*: seq[string]
    args*: seq[string]
    deps*: seq[int]   # node IDs this depends on
    state*: NodeState
    depth*: int       # depth in the DAG for parallel execution

  Dag* = object
    nodes*: seq[Node]
    nameToId*: Table[string, int]
    maxDepth*: int    # maximum depth in the DAG
    commands*: seq[Command]  # bidirectional mapping of commands
    baseDir*: string
    nimcache*: string
      ## The directory the build file itself lives in, which is the nimcache.
      ## See `ledgerTargetOf` for why that identity holds and what it is for.
      ## Deliberately NOT `baseDir`: that one is the `.args` search root
      ## (`expandCommand` is its only reader) and has nothing to do with where
      ## artifacts land.

  CliOption* = enum
    Parallel, Force, Rerun, Verbose, Profile, Report, Progress

  ProfileData* = object
    ## What a run measured. `cmdTime` is keyed by the DAG command name and
    ## counts every node that ran, in-process ones included, because that is
    ## what `--report` has always meant: "which phases actually re-ran".
    ## `inproc` is the subset that never reached a process (A2b).
    parseTime*: float
    dagSetupTime*: float
    cmdTime*: Table[string, tuple[sec: float, count: int]]
    execWallTime*: float
    inproc*: int
    inprocWallTime*: float  ## wall spent inside in-process nodes. They still
                            ## run one at a time, but they run WHILE their
                            ## depth's spawned nodes do, so this is time that
                            ## overlaps the fan-out rather than time added in
                            ## front of it, and `execWallTime` already contains
                            ## it at any depth that spawned anything (A2b, and
                            ## the overlap follow-up)

let profileNodes = existsEnv("NIMONY_PROFILE_NODES")
  ## `NIMONY_PROFILE_NODES=1` with `--profile`: one stderr line per node,
  ## `[node] inproc|spawn <phase> <module> <seconds>`, for attributing a
  ## scheduler decision to its cost. Diagnostic only.
  ##
  ## M1 adds memory to the line, which is what the scheduler now also decides
  ## on. An in-process node reports `rss=+N.NMB`: the growth of THIS process's
  ## peak resident size across the node, which is what running it here cost the
  ## driver. A spawned node reports `childpeak=N.NMB` instead --
  ## `getrusage(RUSAGE_CHILDREN)`'s running high-water mark, i.e. the largest
  ## child seen so far and not this one's own peak. It is one syscall, so it is
  ## free enough to print; it cannot be attributed to a single child, so it is
  ## named for what it is. A spawned node's own footprint is in the ledger,
  ## where the tool itself recorded it.

proc initProfileData*(): ProfileData =
  ProfileData(cmdTime: initTable[string, tuple[sec: float, count: int]]())

type
  CmdArg* = object
    ## One argument of an expanded command, kept in the two halves the shell
    ## rendering needs. A `(input "-o:" 0)` slot emits its prefix verbatim and
    ## `quoteShell`s the rest, which is one shell word and therefore one argv
    ## element -- so the two renderings differ only in the quoting, never in
    ## the word boundaries.
    prefix*: string  ## emitted verbatim, never quoted
    body*: string    ## emitted `quoteShell`ed unless `raw`
    raw*: bool       ## a token that came out of an `.args` file

proc renderCommand*(parts: seq[CmdArg]): string =
  ## The shell line. Byte-identical to what `expandCommand` produced before
  ## the argv split: the same `addSpace` rule, the same `quoteShell`
  ## placement, `.args` tokens still inserted verbatim.
  result = ""
  for i in 0 ..< parts.len:
    if result.len > 0 and result[^1] != ' ': result.add ' '
    if parts[i].prefix.len > 0: result.add parts[i].prefix
    if parts[i].raw: result.add parts[i].body
    else: result.add parts[i].body.quoteShell

proc argvOf*(parts: seq[CmdArg]): seq[string] =
  ## The same command as an argv, `parts[0]` being the tool. Only meaningful
  ## when `hasRawArgs` is false; see there.
  result = newSeq[string](parts.len)
  for i in 0 ..< parts.len:
    result[i] = parts[i].prefix & parts[i].body

proc hasRawArgs*(parts: seq[CmdArg]): bool =
  ## Did an `.args` file contribute to this command? Those tokens are
  ## pre-split shell words whose argv nifmake never reconstructed, so a node
  ## carrying one is not offered to the in-process path.
  result = false
  for i in 0 ..< parts.len:
    if parts[i].raw: return true

proc searchPathFor(name: string): string =
  ## `name` in one of `PATH`'s directories, absolute, or `""`. Hand-rolled
  ## rather than `os.findExe` for one reason: `findExe` looks in the CURRENT
  ## DIRECTORY first on Windows (and on POSIX for any name holding a `/`),
  ## and the current directory is the candidate this whole resolution exists
  ## to rule out — a file called `nimony` in the directory a build runs from
  ## is not the compiler.
  result = ""
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0: continue
    let cand = dir / name
    if fileExists(cand): return cand

proc resolveProgram*(name: string): string =
  ## The program a `(cmd …)` template's first token names. A command is
  ## either one of ours (`nimsem`, `hexer`, `nifasm`, a `{.build.}` tool) or
  ## an external program (`cc`, the system linker, `nim` as a builder), and
  ## the two resolve differently:
  ##
  ## * ours live next to the running executable, so `bin*/` wins and answers
  ##   with an absolute path;
  ## * an external one is looked up in `PATH` here rather than left to the
  ##   shell, so that what nifmake runs is what nifmake resolved.
  ##
  ## The current directory is never a candidate for either. It used to be the
  ## FIRST one (`tooldirs.findTool` began with `fileExists(name)`), and the
  ## hit was returned as a bare word, which a shell then resolved through
  ## `PATH` again — so a build whose `--out` binary was called `nimony` and
  ## sat in the cwd answered its CTFE sub-compile with `/bin/sh: nimony:
  ## command not found`.
  ##
  ## A name that is nowhere is returned unchanged: the shell's "command not
  ## found" is then the truth about it, and `generateMakefile` must still be
  ## able to write a rule for a program this machine does not have.
  let exe = name.addFileExt(ExeExt)
  if name.isAbsolute: return exe
  let ours = toolDir(exe)
  if fileExists(ours): return ours
  let onPath = searchPathFor(exe)
  if onPath.len > 0: return onPath
  result = name

proc addFilename(parts: var seq[CmdArg]; filename, prefix, suffix: string) =
  if filename.len > 0:
    # This is not a bug, a suffix is always assumed to be part of the filename
    # and so also subject to quoting:
    parts.add CmdArg(prefix: prefix, body: suffix & filename, raw: false)

proc expandCommandArgs*(cmd: Command; inputs, outputs, args: seq[string];
                        baseDir: string): seq[CmdArg] =
  ## Walk a `(cmd …)` template with one node's inputs/outputs/args and produce
  ## the argument list. `renderCommand` turns it into the shell line the DAG
  ## has always run; `argvOf` turns it into what `commandLineParams()` would
  ## report inside the tool.
  result = @[]
  if cmd.slots.len == 0:
    quit "undeclared command: " & cmd.name

  var toolArgs: seq[string] = @[]
  var first = 0
  if cmd.slots[0].kind == csLiteral:
    let tool = resolveProgram(cmd.slots[0].text)
    result.add CmdArg(body: tool)
    first = 1
    if baseDir.len > 0 and cmd.ext.len > 0:
      let argsFile = findArgs(baseDir, extractArgsKey(tool) & cmd.ext)
      processArgsFile argsFile, toolArgs

  for si in first ..< cmd.slots.len:
    let slot = cmd.slots[si]
    case slot.kind
    of csLiteral:
      # each literal is one argument; without quoting an argument
      # containing a space (e.g. a forwarded `--define:key=a b` or a path)
      # splits into several (tool names and filenames are quoted already)
      result.add CmdArg(body: slot.text)
    of csArgs:
      # Add explicit arguments from the .nif file
      for i in 0..<args.len:
        result.add CmdArg(body: args[i])
      # Add tool-specific arguments (from .args files)
      for arg in toolArgs:
        result.add CmdArg(body: arg, raw: true)
    of csInput, csOutput:
      let files = if slot.kind == csOutput: outputs else: inputs
      let L = files.len
      var a = 0
      var b = 0
      if slot.hasA:
        a = slot.a
        if a < 0: a = L + a
        b = a
      if slot.hasB:
        b = slot.b
        if b < 0: b = L + b
      for i in a..b:
        if i >= 0 and i < files.len:
          addFilename(result, files[i], slot.prefix, slot.suffix)

proc expandCommand*(cmd: Command; inputs, outputs, args: seq[string]; baseDir: string): string =
  ## The fully expanded shell line, for `generateMakefile` and for every caller
  ## that only needs the string.
  renderCommand(expandCommandArgs(cmd, inputs, outputs, args, baseDir))

proc registerCommand(dag: var Dag; cmdName: string; ext: string): int =
  for i in 0..<dag.commands.len:
    if dag.commands[i].name == cmdName:
      return i
  result = dag.commands.len
  dag.commands.add Command(name: cmdName, ext: ext)

proc addNode(dag: var Dag; cmdName: string;
             inputs, outputs, args: sink seq[string]; ext: string): int =
  ## Add a build node to the DAG and return its ID
  result = dag.nodes.len
  let cmdIdx = registerCommand(dag, cmdName, ext)
  let node = Node(
    cmdIdx: cmdIdx,
    inputs: inputs,
    outputs: outputs,
    args: args,
    deps: @[],
    state: nsUnvisited,
    depth: 0
  )
  dag.nodes.add(node)

  # Map outputs to this node
  for output in outputs:
    dag.nameToId[output] = result

proc findDependencies(dag: var Dag; nodeId: int) =
  ## Find dependencies for a node and link them
  var node = addr dag.nodes[nodeId]

  for input in node.inputs:
    if input in dag.nameToId:
      let depId = dag.nameToId[input]
      if depId != nodeId and depId notin node.deps:
        node.deps.add(depId)

proc removeOutdatedArtifacts(node: Node; opt: set[CliOption]) =
  ## Remove outdated build artifacts for a node. Only used with --force;
  ## removing before normal incremental builds breaks tools that use OnlyIfChanged.
  for output in node.outputs:
    if vfsExists(output):
      try:
        vfsRemove(output)
        if Verbose in opt:
          echo "Removed outdated artifact: ", output
      except:
        stderr.writeLine "Warning: Could not remove outdated artifact: ", output

proc needsRebuild*(node: Node): bool =
  ## Check if a node needs to be rebuilt
  result = false

  # Nodes with no outputs are side-effectful (e.g. idetools printing to stdout);
  # always run them.
  if node.outputs.len == 0:
    return true

  # Check if any output is missing
  for output in node.outputs:
    if not vfsExists(output):
      return true

  # Use the *freshest* output as the staleness reference (max instead of
  # min). Tools may write some outputs OnlyIfChanged — when the content
  # didn't change those preserve their old mtime. Using min would treat
  # "preserved old" as the floor and re-fire the node forever even though
  # some other output (always written) is fresh enough to prove "we ran
  # since the inputs last changed".
  var freshestOutput = low(int64)
  for output in node.outputs:
    let outputTime = vfsMtime(output)
    if outputTime > freshestOutput:
      freshestOutput = outputTime

  for input in node.inputs:
    if vfsExists(input):
      let inputTime = vfsMtime(input)
      if inputTime > freshestOutput:
        return true

proc visit(nodes: var seq[Node]; nodeId: int; sortedNodes: var seq[int]; maxDepth: var int): bool =
  case nodes[nodeId].state
  of nsInStack:
    # Cycle detected
    result = false
  of nsVisited:
    result = true
  of nsUnvisited:
    nodes[nodeId].state = nsInStack
    var nodeDepth = 0
    for depId in nodes[nodeId].deps:
      if not visit(nodes, depId, sortedNodes, maxDepth):
        result = false
        return
      nodeDepth = max(nodeDepth, nodes[depId].depth)
    nodes[nodeId].depth = nodeDepth + 1
    maxDepth = max(maxDepth, nodes[nodeId].depth)
    nodes[nodeId].state = nsVisited
    sortedNodes.add(nodeId)
    result = true

proc topologicalSort*(dag: var Dag): seq[int] =
  ## Perform topological sort on the DAG, then re-order by depth so the
  ## scheduler in `runDag` can group same-depth nodes contiguously and
  ## dispatch them via `execProcesses` in parallel. The DFS post-order is
  ## already a valid topological order, but it interleaves depths — and
  ## the `currentDepth`-batching loop downstream then sees one node per
  ## batch and serializes the build.
  result = @[]
  dag.maxDepth = 0

  for i in 0..<dag.nodes.len:
    if dag.nodes[i].state == nsUnvisited:
      if not visit(dag.nodes, i, result, dag.maxDepth):
        quit "Circular dependency detected in build graph"

  let nodes = addr dag.nodes
  result.sort proc(a, b: int): int = cmp(nodes[a].depth, nodes[b].depth)

proc executeCommand(command: string): bool =
  ## Execute a shell command and return success status
  try:
    let exitCode = execShellCmd(command)
    result = exitCode == 0
  except:
    result = false

# --- the run-node relay ---------------------------------------------------
#
# The seam Phase A2b fills: a relay that gets first refusal on every node the
# DAG decides to run. Today's default declines everything, so both paths below
# behave exactly as they did — the sequential one shells out, the parallel one
# batches the depth into `execProcesses`.
#
# The answer is a tri-state rather than a bool because A2b routes SOME
# commands in-process (the phases it has registered) while the rest of the
# same DAG depth still has to fan out: `RunSpawn` sends the node to the batch,
# the two `Handled` answers keep it out of it and report the outcome.

type
  RunNodeStatus* = enum
    RunSpawn,          ## the relay declines; nifmake runs the command itself
    RunHandledOk,      ## the relay ran it in-process, successfully
    RunHandledFailed   ## the relay ran it in-process, and it failed

  RunNodeRequest* = object
    ## Everything a relay needs to decide whether it can run this node itself.
    ## `command` is the fully expanded shell line the default path would run,
    ## so a relay that declines costs nothing extra and one that accepts still
    ## has the exact argv to report or fall back to.
    name*: string        ## the `cmd` name from the DAG: `nifler`, `cc`, …
    command*: string
    argv*: seq[string]   ## the same command as an argv; `argv[0]` is the tool
    rawArgs*: bool       ## an `.args` file contributed; `argv` is not faithful
    inputs*: seq[string]
    outputs*: seq[string]
    args*: seq[string]
    baseDir*: string
    readyAtDepth*: int   ## how many nodes of this DAG depth are about to run,
                         ## this one included. The scheduler of JIT.md 6.2
                         ## weighs it against the core count; a sequential run
                         ## reports 1, which is the truth there.
    depthSeq*: int       ## a counter that changes once per depth, so a relay
                         ## deciding per DEPTH can reuse its answer for every
                         ## node of that depth without a table
    depthPeers*: seq[DepthPeer]  ## every node about to run at this depth
                         ## (this one included), as the ledger keys them; what
                         ## a per-depth decision is made from. Empty on the
                         ## sequential path, where a depth is one node.
    decideOnly*: bool    ## ask, do not run. The parallel path asks the whole
                         ## depth first so it can START the spawned nodes, and
                         ## only then runs the accepted ones -- on this thread,
                         ## while the children are in flight. A relay answering
                         ## a `decideOnly` request must do everything a decline
                         ## needs (spilling the node's inputs, its own
                         ## accounting) and nothing an acceptance does:
                         ## `RunHandledOk` here means "I will run this", and the
                         ## same node comes back with `decideOnly = false`.

  DepthPeer* = object
    name*: string    ## the `cmd` name
    module*: string  ## `ledgerModuleOf` the node: the module suffix of its
                     ## first output, "" for a whole-program node

proc spawnEverything(req: RunNodeRequest): RunNodeStatus {.nimcall.} = RunSpawn

var runNodeRelay*: proc (req: RunNodeRequest): RunNodeStatus {.nimcall.} = spawnEverything
  ## The one piece of ambient state this module keeps, and it is a seam rather
  ## than a setting: the relays of `src/lib/vfs.nim` have the same shape and
  ## the same reason (a `nimcall` proc has nowhere to put a context).

proc relayInstalled*(): bool =
  ## Is anything but the default relay in place? Callers use it to skip work
  ## that only a real relay would consume.
  runNodeRelay != spawnEverything

proc offerNode(parts: seq[CmdArg]; name, command: string; node: Node;
               baseDir: string; readyAtDepth: int; depthSeq: int;
               peers: seq[DepthPeer]; decideOnly = false): RunNodeStatus =
  ## Ask the relay. Named so the two paths in `runDag` agree, and guarded so
  ## the default relay costs nothing: assembling the request copies five
  ## `seq`s per node, and the make loop runs it for every node of every depth.
  if runNodeRelay == spawnEverything: return RunSpawn
  runNodeRelay(RunNodeRequest(
    name: name, command: command,
    argv: argvOf(parts), rawArgs: hasRawArgs(parts),
    inputs: node.inputs, outputs: node.outputs, args: node.args,
    baseDir: baseDir, readyAtDepth: readyAtDepth, depthSeq: depthSeq,
    depthPeers: peers, decideOnly: decideOnly))

# --- the cost ledger ------------------------------------------------------
#
# JIT.md 5.2 gives every artifact a `spawn` cost, and nifmake is the only
# process that can measure one: it knows the wall time of a command, and the
# tool inside that command has just written down what its own work cost. The
# difference is the process -- fork, exec, dyld, the tool's own startup, and on
# macOS the Gatekeeper tax that JIT.md 3.3 measures separately.
#
# Collecting it costs one `getMonoTime` pair and one `seq` append per command,
# and one `openLedger` + `saveLedger` per run. Writing a fragment per command
# instead would cost ~124 us each -- serially, in this single-threaded process,
# between two spawns -- which is 5.8 ms on a forced hello world's 47 commands
# against a 420 ms build. `ledger.SpawnLog` explains the trade in full.

proc ledgerModuleOf(node: Node): string =
  ## Which module a node's spawn belongs to: the suffix of its first output,
  ## which is what the tool inside also keyed its own sample with. A node with
  ## no output is a whole-program node and keys on the empty string, the same
  ## way `hexer dl` does.
  if node.outputs.len == 0: "" else: moduleSuffixOf(node.outputs[0])

proc noteCommand(log: var SpawnLog; cmdName, module: string; start: MonoTime) =
  let wallNs = (getMonoTime() - start).inNanoseconds
  log.noteSpawn(cmdName, module, wallNs)

proc failed(arg: string) =
  stdout.write "nifmake: "
  stdout.writeLine arg

proc toSeconds*(d: Duration): float =
  float(d.inNanoseconds) / 1e9

proc recordCmdTime(profile: var ProfileData; cmdName: string; sec: float) =
  if cmdName notin profile.cmdTime:
    profile.cmdTime[cmdName] = (0.0, 0)
  var e = profile.cmdTime[cmdName]
  e.sec += sec
  e.count += 1
  profile.cmdTime[cmdName] = e

type
  CmdStatus = enum
    Enqueued, Running, Finished

  Progressor = object
    ## Live percentage indicator. `total` is the number of nodes we expect to
    ## (re)build this run; `done` counts the ones that actually ran. The shown
    ## percentage is remapped into `[lo, hi]` so a caller that runs nifmake in
    ## several phases (Nimony's frontend/backend split) can hand each phase a
    ## sub-range and present one continuous 0..100% bar across processes.
    active: bool
    done, total, lo, hi: int

proc nodeLabel(dag: Dag; node: Node): string =
  ## Short human-facing label for the artifact a node produces.
  if node.outputs.len > 0: extractFilename(node.outputs[0])
  else: dag.commands[node.cmdIdx].name

proc countToBuild(dag: var Dag; sortedNodes: seq[int]; opt: set[CliOption]): int =
  ## Estimate how many nodes will run, propagating staleness along the DAG:
  ## a node rebuilds if it is stale itself or any dependency will rebuild.
  ## `sortedNodes` is depth-ordered (deps first), so a single forward pass
  ## suffices. This is an upper bound — a dependency written `OnlyIfChanged`
  ## may not actually re-trigger its dependents — so the bar can finish a hair
  ## early; the caller forces the final reading to `hi`.
  result = 0
  var willBuild = newSeq[bool](dag.nodes.len)
  for nodeId in sortedNodes:
    var w = Force in opt or Rerun in opt or needsRebuild(dag.nodes[nodeId])
    if not w:
      for depId in dag.nodes[nodeId].deps:
        if willBuild[depId]: w = true; break
    willBuild[nodeId] = w
    if w: inc result

proc draw(p: Progressor; label: string) =
  if not p.active: return
  let frac = if p.total <= 0: 100 else: clamp(p.done * 100 div p.total, 0, 100)
  let pct = p.lo + frac * (p.hi - p.lo) div 100
  # `\r` rewinds to column 0, `\e[K` clears any leftover from a longer label.
  # The trailing `\r` parks the cursor back at column 0 so a child process that
  # streams its own output (a compile error, a warning) overwrites the bar in
  # place instead of getting glued onto the end of the parked bar line.
  stdout.write "\r[" & align($pct, 3) & "%] " & label & "\e[K\r"
  stdout.flushFile()

proc finish(p: Progressor) =
  if not p.active: return
  p.draw(if p.hi >= 100: "done" else: "")
  # Only the final phase (`hi == 100`) closes the line; earlier phases leave the
  # cursor parked so the next nifmake process overwrites the same line via `\r`.
  if p.hi >= 100:
    stdout.write "\n"
    stdout.flushFile()

# --- a depth's spawned batch --------------------------------------------
#
# `execProcesses` starts a depth's children and does not come back until the
# last one is reaped, so a depth's in-process nodes could only run before it or
# after it -- and A2b ran them BEFORE, which put their serial time in front of
# the fan-out instead of inside it (~0.1 s on a forced stdlib rebuild;
# `bench/results/2026-09-06/progress.md` run 3b, and the follow-up named in
# JIT_IMPL.md's A2b row). `SpawnBatch` is the same loop with the starting split
# from the waiting: `fill` occupies the job slots, `poll` reaps what has
# finished without blocking (called between in-process nodes), `drain` finishes
# the batch.
#
# `execProcesses`'s semantics are kept exactly: at most `jobs` children at a
# time, the same `{poStdErrToStdOut, poParentStreams, poEvalCommand}` options,
# the same "mark it Running and stamp its start time" before a child starts and
# the same accounting after one exits, and the highest ABSOLUTE exit code as
# the result. One thing is deliberately not copied: `waitpid(-1, ...)`, which
# reaps ANY child of this process. It is safe inside `execProcesses`, which
# owns every child for its whole duration; it is not safe here, where the point
# is that this thread is running an in-process nimsem node beside the batch and
# that node may spawn a sub-compile of its own.

type
  SpawnBatch = object
    ## One DAG depth's spawned nodes. The per-command `seq`s are parallel and
    ## indexed by command; `slotProc`/`slotCmd` are indexed by job slot, and a
    ## `nil` in `slotProc` is a free slot.
    commands: seq[string]
    cmdNames: seq[string]
    labels: seq[string]
    modules: seq[string]
    startTimes: seq[MonoTime]
    status: seq[CmdStatus]
    slotProc: seq[Process]
    slotCmd: seq[int]
    started: int      ## commands handed to a process so far
    reaped: int       ## commands whose process has been waited for
    maxExitCode: int

proc initSpawnBatch(commands, cmdNames, labels, modules: seq[string];
                    maxJobs: int): SpawnBatch =
  ## `maxJobs` of 0 means "all cores", which is `execProcesses`'s own default
  ## and therefore what `--parallel`/`-j` without a number has always meant.
  let n = commands.len
  var slots = maxJobs
  if slots <= 0: slots = countProcessors()
  if slots < 1: slots = 1
  if slots > n: slots = n
  result = SpawnBatch(
    commands: commands, cmdNames: cmdNames, labels: labels, modules: modules,
    startTimes: newSeq[MonoTime](n), status: newSeq[CmdStatus](n),
    slotProc: newSeq[Process](slots), slotCmd: newSeq[int](slots),
    started: 0, reaped: 0, maxExitCode: 0)

proc fill(b: var SpawnBatch) =
  ## Start a child in every free slot until the batch runs out of commands.
  for s in 0 ..< b.slotProc.len:
    if b.started >= b.commands.len: break
    if b.slotProc[s] != nil: continue
    let idx = b.started
    b.status[idx] = Running
    b.startTimes[idx] = getMonoTime()
    b.slotProc[s] = startProcess(b.commands[idx],
      options = {poStdErrToStdOut, poParentStreams, poEvalCommand})
    b.slotCmd[s] = idx
    inc b.started

proc reapSlot(b: var SpawnBatch; s: int; prog: var Progressor;
              spawns: var SpawnLog; profile: ptr ProfileData) =
  ## An exited child: its exit code into the batch's, its wall time into the
  ## ledger and the profile, its slot back into the pool. Exactly what
  ## `afterRunEvent` did, inline, because a closure per depth is what
  ## AGENTS.md asks this module not to grow.
  let idx = b.slotCmd[s]
  let p = b.slotProc[s]
  let code = abs(p.peekExitCode())
  if code > b.maxExitCode: b.maxExitCode = code
  b.status[idx] = Finished
  inc prog.done
  prog.draw(b.labels[idx])
  spawns.noteCommand(b.cmdNames[idx], b.modules[idx], b.startTimes[idx])
  if profile != nil:
    let sec = toSeconds(getMonoTime() - b.startTimes[idx])
    profile[].recordCmdTime(b.cmdNames[idx], sec)
    if profileNodes:
      stderr.writeLine "[node] spawn  " & b.cmdNames[idx] & " " & b.modules[idx] &
        " " & sec.formatFloat(ffDecimal, 4) & " ready=" & $b.commands.len &
        " childpeak=" & formatMB(peakChildRssBytes()) & "MB"
  close(p)
  b.slotProc[s] = nil
  inc b.reaped

proc poll(b: var SpawnBatch; prog: var Progressor; spawns: var SpawnLog;
          profile: ptr ProfileData): bool =
  ## Reap every child that has already exited and refill the slots it freed,
  ## without ever blocking. Called between in-process nodes, so a child that
  ## finished while this thread was busy is replaced right away instead of
  ## leaving a core idle until the drain.
  result = false
  for s in 0 ..< b.slotProc.len:
    if b.slotProc[s] == nil: continue
    if running(b.slotProc[s]): continue
    reapSlot(b, s, prog, spawns, profile)
    result = true
  if result: fill(b)

proc firstLiveSlot(b: SpawnBatch): int =
  result = -1
  for s in 0 ..< b.slotProc.len:
    if b.slotProc[s] != nil: return s

proc drain(b: var SpawnBatch; prog: var Progressor; spawns: var SpawnLog;
           profile: ptr ProfileData): int =
  ## Finish the batch and answer with the highest absolute exit code, which is
  ## what `execProcesses` returned.
  ##
  ## How it waits depends on whether there is anything left to START, because
  ## that is what decides whether waiting on the WRONG child costs anything:
  ##
  ## * commands still queued -- a slot that frees up has to be refilled at
  ##   once, so the wait has to wake on *whichever* child finishes first.
  ##   `execProcesses` gets that from `waitpid(-1, ...)`, which is not
  ##   available here (see the note above `SpawnBatch`), so this polls on a
  ##   1 ms tick. Half a millisecond of slot idle per completion, against a
  ##   node that costs tens of them.
  ## * nothing queued -- every remaining child only has to finish, and no slot
  ##   is waiting for one. Blocking on any of them is then exact and free, so
  ##   the tail of every batch, and every batch that fits in the slots at once
  ##   (a single `link` node, most depths of an edit rebuild), never polls.
  fill(b)
  while b.reaped < b.commands.len:
    if poll(b, prog, spawns, profile): continue
    let live = firstLiveSlot(b)
    if live < 0: break   # no child left and none to start: nothing to wait for
    if b.started < b.commands.len:
      sleep(1)
    else:
      discard waitForExit(b.slotProc[live])
      reapSlot(b, live, prog, spawns, profile)
  result = b.maxExitCode

type
  InprocNode = object
    ## A node the relay has ACCEPTED but not yet run. The whole depth is
    ## decided before anything starts, so the spawned half can be in flight
    ## while this half runs on this thread; the expansion is kept because it
    ## is what the second, running offer is made with.
    nodeId: int
    parts: seq[CmdArg]
    command: string
    name: string

proc runDag*(dag: var Dag; opt: set[CliOption]; profile: ptr ProfileData = nil;
             progressLo = 0; progressHi = 100; maxJobs = 0): bool =
  ## Execute the DAG in topological order.
  ##
  ## `maxJobs` is the concurrency cap of `--parallel:N` / `-j:N` (0 = all
  ## cores, the `execProcesses` default). It is a parameter rather than the
  ## module-level `var` it used to be so that two callers in one process --
  ## nimony's frontend and backend graphs, and a CTFE sub-build beside them --
  ## cannot inherit each other's setting.
  result = true
  var spawns = default(SpawnLog)
    ## What every command that reached a process cost. Folded into
    ## `<nimcache>/ledger.nif` once, at the end.
  var profileInproc = 0
    ## Nodes the relay ran without a process. Counted here rather than read off
    ## `profile.cmdTime` because that table blends both kinds by design.
  let sortStart = if profile != nil: getMonoTime() else: MonoTime()
  let sortedNodes = topologicalSort(dag)
  if profile != nil:
    profile[].dagSetupTime = toSeconds(getMonoTime() - sortStart)

  # The live bar is routed only where it makes sense: it needs an interactive
  # terminal, and it must not corrupt `--verbose`'s line output or `--report`'s
  # machine-readable stdout.
  var prog = Progressor(
    active: Progress in opt and Verbose notin opt and Report notin opt and isatty(stdout),
    done: 0, total: 0, lo: progressLo, hi: progressHi)
  if prog.active:
    prog.total = countToBuild(dag, sortedNodes, opt)
    prog.draw("")  # paint the starting reading (lo%) right away

  if Parallel in opt:
    var depthSeq = 0   # bumps once per depth; see `RunNodeRequest.depthSeq`
    var i = 0
    while i < sortedNodes.len:
      let currentDepth = dag.nodes[sortedNodes[i]].depth
      var commands: seq[string] = @[]
      var nodeIds: seq[int] = @[]
      var cmdNames: seq[string] = @[]
      var labels: seq[string] = @[]  # captured by afterRunEvent (can't capture `dag`)
      # Same shape and the same reason: `afterRunEvent` sees an index, not a
      # node, so the ledger key of a node has to be resolved before the batch
      # runs.
      var modules: seq[string] = @[]

      # Pass 1: which nodes of this depth are going to run. The scheduler of
      # JIT.md 6.2 asks "how many ready nodes are there at this depth" before
      # it decides whether the next one is worth a process, and the relay is
      # consulted per node, so the count has to exist before the first offer.
      # `needsRebuild` is still called exactly once per node -- this is the
      # same single pass the collection loop used to make, split in two.
      var pending: seq[int] = @[]
      while i < sortedNodes.len and dag.nodes[sortedNodes[i]].depth == currentDepth:
        if Force in opt or Rerun in opt or needsRebuild(dag.nodes[sortedNodes[i]]):
          pending.add sortedNodes[i]
        inc i

      # The depth as the relay sees it, built once: a per-depth decision
      # (JIT.md 6.2's "ready nodes at this depth") needs every node's ledger
      # key, and it needs them before the first node is offered.
      inc depthSeq
      var peers: seq[DepthPeer] = @[]
      if relayInstalled():
        for nodeId in pending:
          peers.add DepthPeer(name: dag.commands[dag.nodes[nodeId].cmdIdx].name,
                              module: ledgerModuleOf(dag.nodes[nodeId]))

      # Pass 2: DECIDE the whole depth. Nothing runs here -- the relay is asked
      # with `decideOnly`, so it still declines (and spills the declined
      # node's inputs) exactly as before, but an acceptance is a promise, not
      # a result. The depth's spawned nodes therefore start before its
      # in-process nodes run instead of after them.
      var inprocNodes: seq[InprocNode] = @[]
      for nodeId in pending:
        let node = addr dag.nodes[nodeId]
        if Force in opt:
          removeOutdatedArtifacts(node[], opt)
        if Verbose in opt:
          echo "Building: ", node.outputs.join(", ")
        let parts = expandCommandArgs(dag.commands[node.cmdIdx], node.inputs, node.outputs, node.args, dag.baseDir)
        let expandedCmd = renderCommand(parts)
        if Verbose in opt:
          echo "Command: ", expandedCmd
        let cmdName = dag.commands[node.cmdIdx].name
        case offerNode(parts, cmdName, expandedCmd, node[], dag.baseDir, pending.len,
                       depthSeq, peers, decideOnly = true)
        of RunSpawn:
          commands.add(expandedCmd)
          nodeIds.add(nodeId)
          cmdNames.add(cmdName)
          labels.add(nodeLabel(dag, node[]))
          modules.add(ledgerModuleOf(node[]))
        of RunHandledOk, RunHandledFailed:
          # `RunHandledFailed` cannot come out of a `decideOnly` offer -- a
          # relay that ran nothing has nothing to fail -- and is folded in
          # here rather than rejected so a relay that answers it anyway is
          # simply run and allowed to fail below.
          inprocNodes.add InprocNode(nodeId: nodeId, parts: parts,
                                     command: expandedCmd, name: cmdName)

      # Pass 3: start the children, run the in-process nodes on this thread
      # while they run, then drain. The depth's wall is now the fan-out's,
      # with the serial half hidden inside it.
      let depthStart = if profile != nil: getMonoTime() else: MonoTime()
      var batch = initSpawnBatch(commands, cmdNames, labels, modules, maxJobs)
      if commands.len > 0:
        fill(batch)

      var inprocFailure = ""
      for k in 0 ..< inprocNodes.len:
        let node = addr dag.nodes[inprocNodes[k].nodeId]
        let cmdName = inprocNodes[k].name
        let inprocStart = getMonoTime()
        # The driver's peak before the node, so the line below can report what
        # the node added to it. A peak is monotone, so the difference is never
        # negative and never over-reports: it is the part of the node's own
        # footprint this process had not already paid for.
        let inprocRss0 = if profileNodes: peakRssBytes() else: 0'i64
        let status = offerNode(inprocNodes[k].parts, cmdName, inprocNodes[k].command,
                               node[], dag.baseDir, pending.len, depthSeq, peers)
        if status == RunHandledFailed:
          if prog.active:
            stdout.write "\n"
            stdout.flushFile()
          inc profileInproc
          if profile != nil:
            profile[].recordCmdTime(cmdName, toSeconds(getMonoTime() - inprocStart))
            profile[].inproc = profileInproc
          failed inprocNodes[k].command
          inprocFailure = inprocNodes[k].command
          break
        # `RunSpawn` here would mean the relay changed its mind between the
        # two offers, which the per-depth memo of `phases.wantsInproc` rules
        # out; running it as an in-process node that did nothing would silently
        # skip it, so it is treated as the failure it is.
        if status == RunSpawn:
          failed "nifmake: relay declined a node it had accepted: " & inprocNodes[k].command
          inprocFailure = inprocNodes[k].command
          break
        # An in-process node still counts as an executed command, so `--report`
        # keeps meaning what it meant, and its wall time is attributed to its
        # phase the way a spawned one's is -- the clock was already running for
        # the ledger, so `--profile` gets the number for free.
        inc prog.done
        inc profileInproc
        prog.draw(nodeLabel(dag, node[]))
        if profile != nil:
          let sec = toSeconds(getMonoTime() - inprocStart)
          profile[].recordCmdTime(cmdName, sec)
          profile[].inprocWallTime += sec
          if profileNodes:
            let peak = peakRssBytes()
            stderr.writeLine "[node] inproc " & cmdName & " " & ledgerModuleOf(node[]) &
              " " & sec.formatFloat(ffDecimal, 4) & " ready=" & $pending.len &
              " rss=+" & formatMB(peak - inprocRss0) & "MB" &
              " peak=" & formatMB(peak) & "MB"
        # Give the finished children their slots back before the next node:
        # this thread is the only one that can start a replacement.
        if commands.len > 0:
          discard poll(batch, prog, spawns, profile)

      let maxExitCode =
        if commands.len > 0: drain(batch, prog, spawns, profile)
        else: 0
      if commands.len > 0 and profile != nil:
        profile[].execWallTime += toSeconds(getMonoTime() - depthStart)
      # The in-process failure is reported first (it happened first) but the
      # children are drained before returning: they are this process's, and
      # leaving them writing into a build that has already failed is worse
      # than the fraction of a second it costs to let them finish.
      if inprocFailure.len > 0:
        return false
      if maxExitCode != 0:
        if prog.active:
          stdout.write "\n"
          stdout.flushFile()
        for i, st in pairs(batch.status):
          if st == Running:
            failed batch.commands[i]
        return false
  else:
    # Sequential execution
    for nodeId in sortedNodes:
      let node = addr dag.nodes[nodeId]
      if Force in opt or Rerun in opt or needsRebuild(node[]):
        if Force in opt:
          removeOutdatedArtifacts(node[], opt)
        if Verbose in opt:
          echo "Building: ", node.outputs.join(", ")
        let parts = expandCommandArgs(dag.commands[node.cmdIdx], node.inputs, node.outputs, node.args, dag.baseDir)
        let expandedCmd = renderCommand(parts)
        if Verbose in opt:
          echo "Command: ", expandedCmd
        let cmdName = dag.commands[node.cmdIdx].name
        let start = getMonoTime()
        # Nothing fans out on this path, so one ready node is the whole truth
        # the scheduler could learn from a count here.
        let status = offerNode(parts, cmdName, expandedCmd, node[], dag.baseDir, 1, 0, @[])
        let ok =
          case status
          of RunSpawn: executeCommand(expandedCmd)
          of RunHandledOk: true
          of RunHandledFailed: false
        if status == RunSpawn:
          # Even a failed command spawned a process, and what that cost is worth
          # knowing: the next run will decide whether to spawn it again.
          spawns.noteCommand(cmdName, ledgerModuleOf(node[]), start)
        else:
          inc profileInproc
        if not ok:
          if profile != nil:
            profile[].recordCmdTime(cmdName, toSeconds(getMonoTime() - start))
            profile[].inproc = profileInproc
          if prog.active:
            stdout.write "\n"
            stdout.flushFile()
          failed expandedCmd
          return false
        inc prog.done
        prog.draw(nodeLabel(dag, node[]))
        if profile != nil:
          let sec = toSeconds(getMonoTime() - start)
          profile[].recordCmdTime(cmdName, sec)
          profile[].execWallTime += sec
      else:
        if Verbose in opt:
          echo "Up to date: ", node.outputs.join(", ")

  prog.finish()
  if profile != nil: profile[].inproc = profileInproc

  # Fold this run's fragments, and the spawn costs it measured, into
  # `<nimcache>/ledger.nif` (JIT_IMPL.md A1d). This is the last moment in a
  # build at which every tool has finished writing its own fragment.
  #
  # The nimcache is `parentDir` of the build file: every `.build.nif` nimony
  # generates is written into `config.nifcachePath` (`deps.nim:907`, `:1237`,
  # `:1916`, `:2075`), so the DAG file's own directory is the nimcache exactly,
  # with no guessing and no new flag. `--base` is the `.args` search root and is
  # not it. `openLedger` folds `<nimcache>/.ledger/` and `<nimcache>/*/.ledger/`
  # from there, which is the two levels the pipeline writes into.
  #
  # Skipped when nothing ran: an up-to-date build has nothing new to fold and
  # must stay as close to free as it is today.
  if spawns.len > 0:
    consolidate(dag.nimcache, spawns)

proc mescape(p: string): string =
  when defined(windows):
    result = p.replace("\\", "/")
  else:
    result = p.replace(":", "\\:") # Rule separators
  result = result.multiReplace({
    " ": "\\ ",   # Spaces
    "#": "\\#",   # Comments
    "$": "$$",    # Variables
    "(": "\\(",   # Function calls
    ")": "\\)",
    "*": "\\*",   # Wildcards
    "[": "\\[",   # Pattern matching
    "]": "\\]"
  })

proc generateMakefile*(dag: Dag; filename: string) =
  ## Generate a Makefile from the DAG
  var content = "# Generated by nifmake\n\n"
  content.add ".PHONY: all clean\n\n"

  # Add all target
  content.add "all:"
  for node in dag.nodes:
    for output in node.outputs:
      content.add " " & mescape(output)
  content.add "\n\n"

  # Add rules for each node
  for node in dag.nodes:
    # Target line
    content.add node.outputs.map(mescape).join(" ")
    content.add ":"
    for input in node.inputs:
      content.add " " & mescape(input)
    content.add "\n"

    # Command line
    let expandedCmd = expandCommand(dag.commands[node.cmdIdx], node.inputs, node.outputs, node.args, dag.baseDir)
    content.add "\t" & mescape(expandedCmd) & "\n\n"

  # Add clean target
  content.add "clean:\n"
  content.add "\trm -f"
  for node in dag.nodes:
    for output in node.outputs:
      content.add " " & mescape(output)
  content.add "\n"

  writeFile(filename, content)

proc parseSlotArgs(n: var Cursor; slot: var CmdSlot) =
  ## `(input|output [prefix] [a [b]] [suffix])`. The cursor is already inside
  ## the subtree.
  if n.hasMore and n.kind == StrLit:
    slot.prefix = n.strVal
    inc n
  if n.hasMore and n.kind == IntLit:
    slot.a = int n.intVal
    slot.hasA = true
    inc n
  if n.hasMore and n.kind == IntLit:
    slot.b = int n.intVal
    slot.hasB = true
    inc n
  if n.hasMore and n.kind == StrLit:
    slot.suffix = n.strVal
    inc n
  while n.hasMore: skip n

proc parseCommandDefinition(n: var Cursor; dag: var Dag) =
  if n.kind == SymbolDef:
    let cmdName = pool.syms[n.symId]
    inc n

    var slots: seq[CmdSlot] = @[]
    var argsext = ".args"
    while n.hasMore:
      if n.kind == StrLit:
        slots.add CmdSlot(kind: csLiteral, text: n.strVal)
        inc n
      elif n.isTagLit:
        let tag = globalTags.tags[n.cursorTagId]
        case tag
        of "argsext":
          n.into:
            if n.hasMore and n.kind == StrLit:
              argsext = n.strVal
              inc n
        of "args":
          slots.add CmdSlot(kind: csArgs)
          skip n
        of "input", "output":
          var slot = CmdSlot(kind: if tag == "output": csOutput else: csInput)
          n.into:
            parseSlotArgs(n, slot)
          slots.add slot
        else:
          quit "unsupported tag in `cmd` definition: " & tag
      else:
        quit "unsupported token in `cmd` definition: " & $n.kind
    let cmdIdx = registerCommand(dag, cmdName, argsext)
    dag.commands[cmdIdx].slots = slots
  else:
    quit "expected symbol definition in `cmd` definition"

proc parseDoRule(n: var Cursor; dag: var Dag) =
  var cmdName: string
  if n.kind == Symbol:
    cmdName = pool.syms[n.symId]
    inc n
  elif n.kind == Ident:
    cmdName = n.strVal
    inc n
  else:
    quit "expected symbol or identifier in `do` rule"

  var inputs: seq[string] = @[]
  var outputs: seq[string] = @[]
  var args: seq[string] = @[]

  # Parse imports and results
  while n.hasMore:
    if n.isTagLit:
      let tag = globalTags.tags[n.cursorTagId]
      n.into:
        if tag == "input":
          if n.hasMore and n.kind == StrLit:
            inputs.add(n.strVal)
            inc n
        elif tag == "output":
          if n.hasMore and n.kind == StrLit:
            outputs.add(n.strVal)
            inc n
        elif tag == "args":
          while n.hasMore:
            if n.kind == StrLit:
              args.add(n.strVal)
            inc n
        else:
          quit "unsupported tag in `do` definition: " & tag
        # Body must consume all children — mop up anything we didn't recognise.
        while n.hasMore: skip n
    else:
      quit "expected `input` or `output` in `do` definition, but found: " & $n.kind

  discard addNode(dag, cmdName, inputs, outputs, args, ".args")

proc parseNifFile*(filename: string; baseDir: sink string): Dag =
  ## Parse a .nif file and build the DAG
  result = Dag(baseDir: baseDir, nimcache: filename.parentDir)

  if not vfsExists(filename):
    quit "File not found: " & filename

  var buf = parseFromFile(filename)
  var n = beginRead(buf)

  # Parse (.nif27)(stmts ...)
  if n.isTagLit:
    n.into:  # enter the (stmts ...) wrapper
      while n.hasMore:
        if n.isTagLit:
          case globalTags.tags[n.cursorTagId]
          of "cmd":
            n.into:
              parseCommandDefinition(n, result)
          of "do":
            n.into:
              parseDoRule(n, result)
          else:
            quit "unknown statement: " & globalTags.tags[n.cursorTagId]
        else:
          quit "expected statement in .nif file, but found: " & $n.kind

  # Find dependencies between nodes
  for i in 0..<result.nodes.len:
    findDependencies(result, i)

# --- machine-readable output ----------------------------------------------
#
# Produced as strings rather than written here, because two different programs
# emit them: the `nifmake` CLI, and the in-process driver in `src/nimony`. The
# bytes have to be the same either way -- `src/hastur/incrementaltests.nim`
# parses the report line -- and a proc that returns the line is the cheapest
# way to make that a property of the code instead of a promise.

proc reportLine*(profile: ProfileData): string =
  ## Machine-readable summary of which commands actually executed during
  ## this run. One line, sorted by command name:
  ##   nifmake-report dceEmit=126 hexer=16 lengc=126 nimsem=121 total=389 inproc=0
  ## Zero-invocation runs print just `nifmake-report total=0 inproc=0` — that
  ## is the up-to-date signal used by the incremental-build regression test.
  ##
  ## `total` is the sum across all commands, in-process ones included; `inproc`
  ## (A2b) is how many of them never reached a process. The prefix up to and
  ## including `total=` is byte-for-byte what it has always been, and the
  ## report parser reads `k=v` pairs, so the new field costs existing callers
  ## nothing.
  var entries = newSeq[(string, int)](profile.cmdTime.len)
  var i = 0
  var total = 0
  for cmd, data in profile.cmdTime.pairs:
    entries[i] = (cmd, data.count)
    inc i
    total += data.count
  entries.sort(proc(a, b: (string, int)): int = cmp(a[0], b[0]))
  result = "nifmake-report"
  for (cmd, count) in entries:
    result.add " "
    result.add cmd
    result.add "="
    result.add $count
  result.add " total="
  result.add $total
  result.add " inproc="
  result.add $profile.inproc
  result.add "\n"

proc profileText*(profile: ProfileData): string =
  ## The `--profile` block. An in-process node's wall time is attributed to its
  ## phase exactly like a spawned one's, so the table stays a table of phases
  ## rather than a table of processes.
  result = "\n--- nifmake profile ---\n"
  result.add "  parse .nif:     " & profile.parseTime.formatFloat(ffDecimal, 3) & "s\n"
  result.add "  DAG setup:      " & profile.dagSetupTime.formatFloat(ffDecimal, 3) & "s\n"
  result.add "  executed commands:\n"
  var entries = newSeq[(string, float, int)](profile.cmdTime.len)
  var i = 0
  for cmd, data in profile.cmdTime.pairs:
    entries[i] = (cmd, data.sec, data.count)
    inc i
  entries.sort(proc(a, b: (string, float, int)): int = cmp(b[1], a[1]))
  for (cmd, sec, count) in entries:
    result.add "    " & cmd.alignLeft(12) & " " & sec.formatFloat(ffDecimal, 3).align(8) &
               "s  (" & $count & " invocations)\n"
  let execTotal = profile.cmdTime.values.toSeq.foldl(a + b.sec, 0.0)
  result.add "  exec total:     " & execTotal.formatFloat(ffDecimal, 3) & "s\n"
  result.add "  in-process:     " & $profile.inproc & " of " &
             $(profile.cmdTime.values.toSeq.foldl(a + b.count, 0)) & " commands\n"
  result.add "  wall time:      " & profile.execWallTime.formatFloat(ffDecimal, 3) &
             "s  (" & profile.inprocWallTime.formatFloat(ffDecimal, 3) &
             "s in-process, serial, overlapping it)\n"
  result.add "---\n"
