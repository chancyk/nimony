#       Nimony
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Dependency analysis for Nimony.

#[

- Build the graph. Every node is a list of files representing the main source file plus its included files.
  - for this we also need the config so that the paths can be resolved properly
- Every node also has a list of dependencies. Every single dependency is a dependency to a modules's interface!

]#

when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "untyped".}
import std/[os, tables, sets, syncio, hashes, assertions, strutils, formatfloat, dirs, paths, algorithm, monotimes]
import semos, nifconfig, nimony_model, semdata, langmodes
from cli import parseCommonOption
import ".." / gear2 / modnames
when not defined(nimony):
  # The build-graph library, and with it the in-process scheduler. Gated
  # because `hastur boot` compiles nimony WITH nimony, and `dag.nim` is not in
  # nimony's language yet: `osproc.execProcesses` takes two callbacks,
  # `topologicalSort` sorts through a comparison closure, and `strutils.align`
  # / `alignLeft` / `sequtils.foldl` are not there. A booted nimony therefore
  # spawns `nifmake` for every graph -- which is exactly the behaviour of the
  # release before this one, and `nifmake` is a carry tool (host-Nim built at
  # every boot stage), so nothing is lost but the speed-up.
  import ".." / nifmake / dag
import ".." / lib / [tooldirs, platform, nifindexes, symparser, docpaths, argsfinder, vfs, ledger]
from ".." / lib / artifactstore import storeStatsLine
from ".." / lib / nifchecksums import computeChecksum
import ".." / models / nifindex_tags

include ".." / lib / nifprelude
include ".." / lib / compat2
import ".." / lib / nifreader as rd
from ".." / lib / nifcoreparse import parse

type
  FilePair = object
    nimFile: string # can now also be a .nif file. This is used for the eval feature where Nimony
                    # calls itself for an extracted code snippet that must run at compile time.
    modname: string

proc indexFile(config: NifConfig; f: FilePair; bundle: string; preserveDocs = false): string =
  config.nifcachePath / bundle / f.modname & (if preserveDocs: ".sc.idx.nif" else: ".s.idx.nif")

proc parsedFile(config: NifConfig; f: FilePair; preserveDocs = false): string =
  ## `.p.nif` for normal builds, `.pc.nif` (parsed-with-comments) for `nimony doc`.
  ## Splitting the artifact keeps both cache populations valid simultaneously,
  ## so `nimony c` and `nimony doc` on the same project don't fight each other.
  config.nifcachePath / f.modname & (if preserveDocs: ".pc.nif" else: ".p.nif")
proc depsFile(config: NifConfig; f: FilePair; preserveDocs = false): string =
  config.nifcachePath / f.modname & (if preserveDocs: ".pc.deps.nif" else: ".p.deps.nif")
proc deps2File(config: NifConfig; f: FilePair): string = config.nifcachePath / f.modname & ".s.deps.nif"
proc semmedFile(config: NifConfig; f: FilePair; bundle: string; preserveDocs = false): string =
  ## `.s.nif` for normal builds, `.sc.nif` (semmed-with-comments) for `nimony doc`.
  ## Mirrors the `.p.nif` / `.pc.nif` split so the doc and code-gen flows
  ## don't trample each other's post-sem artifact.
  config.nifcachePath / bundle / f.modname & (if preserveDocs: ".sc.nif" else: ".s.nif")
proc docOutDir(config: NifConfig): string =
  ## User-facing destination for `nimony doc`. Honors `--outdir:DIR`; default
  ## is `htmldocs/` (matches Nim's convention).
  if config.outDir.len > 0: config.outDir
  else: "htmldocs"
proc docRelpath(f: FilePair; projectRoot, stdlibRoot: string): string =
  ## Source-derived html relpath, shared by deps.nim (which declares the
  ## output) and dagon (which synthesises the cross-link URL). `nimFile` may
  ## have been recorded relative to the original cwd (when imports resolved
  ## paths against a non-cwd module) — absolutise so the root-prefix tests
  ## match. Slash-normalised so Windows builds produce the same artifacts as
  ## POSIX builds and so `deriveRelpath`'s prefix match agrees with
  ## already-normalised `projectRoot`/`stdlibRoot`.
  deriveRelpath(toUnixPath(toAbsolutePath(f.nimFile)), projectRoot, stdlibRoot)
proc docFile(config: NifConfig; f: FilePair; projectRoot, stdlibRoot: string): string =
  docOutDir(config) / docRelpath(f, projectRoot, stdlibRoot)
proc indexHtmlFile(config: NifConfig): string =
  docOutDir(config) / "theindex.html"
proc docIdxFile(config: NifConfig; f: FilePair): string =
  ## Build-cache sidecar; stays under `nifcachePath` even when the user-facing
  ## HTML is redirected via `--outdir`. Not user-relevant; uses the modname
  ## hash so it can't collide regardless of source layout.
  config.nifcachePath / "docs" / f.modname & ".docidx"
proc backendDirName(config: NifConfig; f: FilePair): string =
  ## Name of the per-main-module directory that holds everything from DCE
  ## onward. Those artifacts are main-specific (a different main means a
  ## different live set) AND backend-specific: hexer runs with `--native` or
  ## without, which changes the main module's `.x.nif` (the synthesized entry
  ## point terminates through `cExit` only on the native backend), and the
  ## generated code, objects and executable below it obviously differ too.
  ##
  ## nifmake decides whether to rerun a node from its declared input and
  ## output FILES, not from the tool's flags, so two backends sharing this
  ## directory do not merely overwrite each other -- whichever ran first wins
  ## and the second reuses its artifacts, because from nifmake's side nothing
  ## changed. Giving each backend its own directory is the same split that
  ## keeps `nimony doc` from fighting `nimony c` over `.p.nif`/`.pc.nif`.
  ##
  ## The C backend keeps the bare module name so existing caches, and every
  ## path a tool derives from one, stay valid.
  result = f.modname
  case config.backend
  of backendC: result.add BackendDirC
  of backendLLVM: result.add BackendDirLLVM
  of backendNative: result.add BackendDirNative
  of backendWasm: result.add BackendDirWasm

proc hexedFile(config: NifConfig; f: FilePair): string = config.nifcachePath / f.modname & ".x.nif"
proc lengcFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  base / f.modname & ".c.nif"
proc optimizedFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  ## Shoggoth rewrites `<modname>.c.nif` into this; `lengc` consumes
  ## it instead. The extra extension keeps the input intact and still extracts
  ## to the same `modname` (splitModulePath stops at the first dot), so lengc's
  ## derived output filename is unchanged.
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  base / f.modname & ".oc.nif"

proc cFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  base / f.modname & ".c"
proc llFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  base / f.modname & ".ll"
proc asmFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  ## arkham rewrites `<modname>.c.nif` (or `.oc.nif`) into this typed asm-NIF.
  ## nifasm consumes the main module's file (by path) and resolves the dependent
  ## modules from disk by suffix, trying `<suffix>.asm.nif` then `<suffix>.nif`
  ## (see nifasm's `openForeignModule`). Each carries an embedded `(.index)` so
  ## no reindex pass is needed.
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  base / f.modname & ".asm.nif"
proc wasmFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  ## ithaqua's whole-program output; the appConsole naming rules of `exeFile`
  ## (`--out`/`--outdir` overrides, else nimcache) with a fixed `.wasm` ext.
  let baseName = f.nimFile.splitFile.name
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  if config.outFile.len > 0 or config.outDir.len > 0:
    let nameOnly = if config.outFile.len > 0: config.outFile else: baseName
    let withExt =
      if nameOnly.splitFile.ext.len > 0: nameOnly
      else: nameOnly.addFileExt("wasm")
    if config.outDir.len > 0: config.outDir / withExt
    else: withExt
  else:
    base / baseName.addFileExt("wasm")

proc genFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  case config.backend
  of backendC: config.cFile(f, backendDir)
  of backendLLVM: config.llFile(f, backendDir)
  of backendNative: config.asmFile(f, backendDir)
  of backendWasm: config.lengcFile(f, backendDir)  # ithaqua consumes Leng directly
proc objFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  base / f.modname & ".o"

# It turned out to be too annoying in practice to have the exe file in
# the current directory per default so we now put it into the nifcache too:
# DCE and everything after is main-specific (different DCE outcomes); use backendDir.
proc exeFile(config: NifConfig; f: FilePair; backendDir: string = ""): string =
  # `--out:PATH` / `--outdir:DIR` override the default
  # `<nimcache>/<backendDir>/<basename>.exe` location for executables.
  # `outDir` / `outFile` are populated by the CLI parser per Nim's
  # semantics (see `cli.nim`'s "out"/"outdir" handlers). Lib and
  # staticlib paths still derive from nimcache — extension fix-ups for
  # those are platform-specific and not in scope yet.
  let baseName = f.nimFile.splitFile.name
  let base = if backendDir.len > 0: config.nifcachePath / backendDir else: config.nifcachePath
  case config.appType
  of appConsole, appGui:
    if config.outFile.len > 0 or config.outDir.len > 0:
      let nameOnly = if config.outFile.len > 0: config.outFile else: baseName
      let withExt =
        if nameOnly.splitFile.ext.len > 0: nameOnly
        else: nameOnly.addFileExt(ExeExt)
      if config.outDir.len > 0: config.outDir / withExt
      else: withExt
    else:
      base / baseName.addFileExt(ExeExt)
  of appLib:
    if config.targetOS == osWindows:
      base / baseName.addFileExt("dll")
    elif config.targetOS in {osMacosx, osIos}:
      base / ("lib" & baseName & ".dylib")
    else:
      base / ("lib" & baseName & ".so")
  of appStaticLib:
    if config.targetOS == osWindows:
      base / baseName.addFileExt("lib")
    else:
      base / ("lib" & baseName & ".a")

proc resolveFileWrapper(paths: openArray[string]; origin: string; toResolve: string): string =
  result = resolveFile(paths, origin, toResolve)
  if not semos.fileExists(result) and toResolve.startsWith("std/"):
    result = resolveFile(paths, origin, toResolve.substr(4))

type
  Node = ref object
    files: seq[FilePair]
    deps: seq[int] # index into c.nodes
    id, parent: int
    active: int
    isSystem: bool
    plugin: string
    cyclicFiles: seq[int] ## indices into `files` that are cyclic module members (need separate outputs)
    plugins: HashSet[string] ## exe basenames of the `{.plugin.}`s this module may
                             ## run: the ones it declares plus, after
                             ## `propagatePlugins`, those of its import closure
    fileDeps: seq[string] ## the `(dependency …)` list the PREVIOUS build's nimsem
                          ## left in `.s.deps.nif`: files a plugin or a `slurp`
                          ## read while semchecking this module

  Command* = enum
    DoCheck, # like `nim check`
    DoTranslate, # translate to C like "nim --compileOnly"
    DoCompile, # like `nim c` but with nifler
    DoRun, # like `nim run`
    DoDoc # like `nim doc`: front-end then dagon backend

  BuildFlag* = enum
    ForceRebuild   ## passes `--force` to nifmake (rebuild all)
    SilentMake     ## suppress make output
    Profile        ## ask nifmake to print its timing profile
    Report         ## ask nifmake to print machine-readable invocation counts
    Stats          ## after build, print total LOC + module count across the dep graph

  CFile = object
    name, obj, customArgs: string

  BackendTool = object
    ## A `{.build(builder, tool[, args[, linkflags]]).}` custom-backend routing
    ## entry: the module `modFile` has its Leng IR piped through `toolName` (a
    ## program built by `builder` from `toolSrc`). Built like a plugin (on demand)
    ## but scheduled like a tool (a node in the nifmake DAG).
    builder: string    ## generic builder command, e.g. "nimony c" / "nim c"
    toolSrc: string    ## the tool's Nim source path
    toolName: string   ## derived exe basename (the nifmake command name)
    args: string       ## extra args forwarded to the tool invocation
    modFile: FilePair  ## the module whose `.c.nif` is routed through the tool
    linkFlags: string  ## optional per-file link flags scoped to this module's
                       ## object in the link manifest ("" = none)

  Bundle = object
    ## A `{.bundle(builder, tool[, args]).}` custom-linker entry: when any module
    ## supplies one it overrides the final link step. `toolName` (built by
    ## `builder` from `toolSrc`) is handed the project link manifest + `args`.
    builder: string
    toolSrc: string
    toolName: string
    args: string

  DepContext = object
    forceRebuild: bool
    cmd: Command
    nifler, nimsem: string
    config: NifConfig
    nodes: seq[Node]
    rootNode: Node
    includeStack: seq[string]
    processedModules: Table[string, int] # modname -> index to c.nodes
    moduleFlags: set[ModuleFlag]
    isGeneratingFinal: bool
    foundPlugins: HashSet[string]
    pluginSources: Table[string, string] ## exe basename -> resolved `.nim` source
                                         ## of every `{.plugin.}` in the graph
    toBuild: seq[CFile]
    backendTools: seq[BackendTool]
    bundles: seq[Bundle]
    passL: seq[string]
    passC: seq[string]
    ocache: Table[string, string] ## modname -> `<nimcache>/ocache/<hash>`, the
                                  ## content-addressed basename of that module's
                                  ## `.o` (and of the `.c` kept beside it).
                                  ## Empty for every build except a
                                  ## compile-time-eval sub-program; see
                                  ## `fillObjectCache`.
    ocacheHit: HashSet[string]    ## the subset of `ocache` whose object was
                                  ## already on disk when the graph was emitted,
                                  ## so its `lengc` and `cc` nodes are left out
                                  ## of the graph entirely.
    ccache: Table[string, string] ## modname -> `<nimcache>/ccache/<hash>.c.nif`,
                                  ## the content-addressed Leng IR of a
                                  ## non-main module of a compile-time-eval
                                  ## sub-program. Empty everywhere else; see
                                  ## `fillCNifCache`.
    ccacheHit: HashSet[string]    ## the subset of `ccache` that was already on
                                  ## disk, so this build wrote the module's
                                  ## `.c.nif` from the cache instead of running
                                  ## `dceEmit` for it.

proc toPair(c: DepContext; f: string): FilePair =
  if f.endsWith(".nif"):
    # For .p.nif files (e.g. from compile-time eval snippets), extract the
    # module suffix directly from the filename rather than recomputing it:
    FilePair(nimFile: f, modname: extractModuleSuffix(f))
  else:
    FilePair(nimFile: f, modname: moduleSuffix(f, c.config.paths))

proc processDep(c: var DepContext; n: var Cursor; current: Node)
proc traverseDeps(c: var DepContext; p: FilePair; current: Node)

proc processInclude(c: var DepContext; it: var Cursor; current: Node) =
  var files: seq[ImportedFilename] = @[]
  var x = it
  skip it
  x.into:  # (include …)
    while x.hasMore:
      var hasError = false
      filenameVal(x, files, hasError, allowAs = false)

      if hasError:
        discard "ignore wrong `include` statement"
      else:
        for f1 in items(files):
          if f1.plugin.len > 0:
            discard "ignore plugin include file, will cause an error in sem.nim"
            continue
          let f2 = resolveFileWrapper(c.config.paths, current.files[current.active].nimFile,
                                      c.config.expandMM(f1.path))
          # check for recursive include files:
          var isRecursive = false
          for a in c.includeStack:
            if a == f2:
              isRecursive = true
              break

          if not isRecursive and semos.fileExists(f2):
            let oldActive = current.active
            current.active = current.files.len
            current.files.add c.toPair(f2)
            traverseDeps(c, c.toPair(f2), current)
            c.includeStack.add f2
            current.active = oldActive
            c.includeStack.setLen c.includeStack.len - 1
          else:
            discard "ignore recursive include"

proc wouldCreateCycle(c: var DepContext; current: Node; p: FilePair): bool =
  var it = current.id
  while it != -1:
    if c.nodes[it].files[0].modname == p.modname:
      return true
    it = c.nodes[it].parent
  return false

proc importSingleFile(c: var DepContext; f1: string; info: NifLineInfo;
                      current: Node; isSystem: bool) =
  let f2 = resolveFileWrapper(c.config.paths, current.files[current.active].nimFile, f1)
  if not semos.fileExists(f2): return
  let p = c.toPair(f2)
  let existingNode = c.processedModules.getOrDefault(p.modname, -1)
  if existingNode == -1:
    var imported = Node(files: @[p], id: c.nodes.len, parent: current.id, isSystem: isSystem,
                        plugin: current.plugin)
    current.deps.add imported.id
    c.processedModules[p.modname] = imported.id
    c.nodes.add imported
    traverseDeps c, p, imported
  else:
    # add the dependency anyway unless it creates a cycle:
    if wouldCreateCycle(c, current, p):
      discard "ignore cycle"
      echo "cycle detected: ", current.files[0].nimFile, " <-> ", p.nimFile
    else:
      current.deps.add existingNode

proc processPluginImport(c: var DepContext; f: ImportedFilename; info: NifLineInfo; current: Node) =
  let f2 = resolveFileWrapper(c.config.paths, current.files[current.active].nimFile, f.path)
  if not semos.fileExists(f2): return
  let p = c.toPair(f2)
  let existingNode = c.processedModules.getOrDefault(p.modname, -1)
  if existingNode == -1:
    var imported = Node(files: @[p], id: c.nodes.len,
                        parent: current.id, isSystem: false, plugin: f.plugin)
    current.deps.add imported.id
    c.processedModules[p.modname] = imported.id
    c.nodes.add imported
    c.foundPlugins.incl f.plugin
  else:
    current.deps.add existingNode

proc importCyclicModule(c: var DepContext; f1: string; info: NifLineInfo;
                        current: Node) =
  ## Merge a cyclic import target into the current node's cycle group.
  let f2 = resolveFileWrapper(c.config.paths, current.files[current.active].nimFile, f1)
  if not semos.fileExists(f2): return
  let p = c.toPair(f2)
  if c.processedModules.hasKey(p.modname):
    return # already part of this or another node
  # Add to current node as a cyclic group member:
  let idx = current.files.len
  current.files.add p
  current.cyclicFiles.add idx
  c.processedModules[p.modname] = current.id
  # Traverse the cyclic module's deps as part of this node:
  let oldActive = current.active
  current.active = idx
  traverseDeps c, p, current
  current.active = oldActive

proc evalDepCond(config: NifConfig; n: Cursor): bool =
  ## Evaluate a `when`-condition expression carried by a `(when ...)` import
  ## marker. Recognises `defined(IDENT)`, boolean `not`/`and`/`or`, the bool
  ## literals `true`/`false`, and falls back to *true* for anything more
  ## complex — the conservative choice, since a false negative here removes
  ## a valid dep from the build graph while a false positive only schedules
  ## a file that the semantic checker will then ignore.
  var n = n
  if n.isTagLit:
    case n.exprKind
    of CallX, CmdX, CallstrlitX, InfixX, PrefixX:
      inc n
      if not n.isIdent:
        return true
      let head = pool.strings[n.strId]
      inc n
      case head
      of "defined":
        if n.isIdent:
          result = config.isDefined(pool.strings[n.strId])
        elif n.isSymbol:
          var name = pool.syms[n.symId]
          extractBasename(name)
          result = config.isDefined(name)
        else:
          result = true
      of "not":
        result = not evalDepCond(config, n)
      of "and":
        result = evalDepCond(config, n)
        skip n
        if result: result = evalDepCond(config, n)
      of "or":
        result = evalDepCond(config, n)
        skip n
        if not result: result = evalDepCond(config, n)
      else:
        result = true  # unknown call — assume true
    of NotX:
      inc n
      result = not evalDepCond(config, n)
    of AndX:
      inc n
      result = evalDepCond(config, n)
      skip n
      if result: result = evalDepCond(config, n)
    of OrX:
      inc n
      result = evalDepCond(config, n)
      skip n
      if not result: result = evalDepCond(config, n)
    of ParX:
      # `(par X)` is just parenthesised grouping — descend into the body.
      # Without this, `not (a or b)` evaluates `not (par ...)` as the
      # conservative-true fallback, and the negation flips to false,
      # silently dropping the conditional `import` from the build graph.
      inc n
      result = evalDepCond(config, n)
    else:
      result = true  # unknown shape — assume true
  elif n.isIdent:
    case pool.strings[n.strId]
    of "true": result = true
    of "false": result = false
    else: result = true  # bare identifier we cannot evaluate — assume true
  else:
    result = true

proc whenMarkerHolds(c: DepContext; x: Cursor): bool =
  ## `(when COND COND ...)` — implicit AND across the children. All must hold
  ## for the import to be live. An empty `(when)` (legacy form, no children)
  ## is treated as live so older deps files keep working.
  assert x.isTagLit and x.stmtKind == WhenS
  var inner = x
  inner.into WhenS:
    while inner.hasMore:
      if not evalDepCond(c.config, inner):
        while inner.hasMore: skip inner  # mop-up before early-exit (return bypasses epilogue)
        return false
      skip inner
  result = true

proc processImport(c: var DepContext; it: var Cursor; current: Node) =
  let info = it.info
  var x = it
  skip it
  x.into:  # (import …)
    # Conditional imports carry a `(when COND...)` marker child. If we can
    # statically prove the condition is false against the active set of
    # `defined(...)` symbols, skip the import entirely. Otherwise step over
    # the marker and process the import normally — the conservative direction
    # for cross-compilation and for conditions we cannot evaluate.
    if x.stmtKind == WhenS:
      if not whenMarkerHolds(c, x):
        return
      skip x, SkipCond
    while x.hasMore:
      var isCyclic = false
      if x.isTagLit and x.exprKind == PragmaxX:
        var y = x
        inc y
        skip y
        if y.substructureKind == PragmasU:
          inc y
          if y.isIdent and pool.strings[y.strId] == "cyclic":
            isCyclic = true

      var files: seq[ImportedFilename] = @[]
      var hasError = false
      if isCyclic:
        # Manually parse the pragmax: enter it, parse the inner filename, skip the pragma
        x.into PragmaxX:
          filenameVal(x, files, hasError, allowAs = false)
          skip x, SkipPragmas # skip (pragmas cyclic)
          while x.hasMore: skip x, SkipFull
      else:
        filenameVal(x, files, hasError, allowAs = true)
      if hasError:
        discard "ignore wrong `import` statement"
      elif isCyclic:
        for f in files:
          importCyclicModule c, f.path, info, current
      else:
        for f in files:
          if f.plugin.len == 0:
            importSingleFile c, f.path, info, current, false
          else:
            processPluginImport c, f, info, current

proc processSingleImport(c: var DepContext; it: var Cursor; current: Node) =
  # process `from import` and `import except` which have a single module expression
  let info = it.info
  var x = it
  skip it
  var files: seq[ImportedFilename] = @[]
  var hasError = false
  x.into:  # (fromimport …) / (importexcept …)
    if x.stmtKind == WhenS:
      if not whenMarkerHolds(c, x):
        return
      skip x, SkipCond  # step past conditional marker, same as processImport
    filenameVal(x, files, hasError, allowAs = true)
    while x.hasMore: skip x  # (the rest of the children are the included/excluded names; processed elsewhere)
  if hasError:
    discard "ignore wrong `from` statement"
  else:
    for f in files:
      if f.plugin.len == 0:
        importSingleFile c, f.path, info, current, false
      else:
        processPluginImport c, f, info, current
      break

proc cmpNames(a, b: string): int =
  ## `sort` needs an explicit comparator under Nimony, whose stdlib has no `cmp`.
  if a < b: -1 elif a > b: 1 else: 0

proc pluginExe(c: DepContext; name: string): string =
  ## Where `semos.runPlugin` looks for the plugin: keep the two in sync.
  c.config.nifcachePath / name.addFileExt(ExeExt)

proc processPlugin(c: var DepContext; it: var Cursor; current: Node) =
  ## `(plugin [(when COND...)] "name")`: nifler's deps-file entry for a
  ## `{.plugin: "name".}` pragma. The name resolves relative to the declaring
  ## file exactly as `semos.runPlugin` resolves it.
  ##
  ## Ignored when this build IS a plugin build (`-d:nimonyPlugin`, set by
  ## `semos.pluginCompileCmd`): plugins are leaves of the build graph. A plugin
  ## whose source imports its declaring module would otherwise require itself,
  ## and the nested builds would recurse without end. Should such a plugin
  ## actually run another plugin at compile time, `runPlugin`'s lazy fallback
  ## still builds that one on demand.
  var x = it
  skip it
  if c.config.isDefined("nimonyPlugin"):
    return
  x.into:  # (plugin …)
    if x.stmtKind == WhenS:
      if not whenMarkerHolds(c, x):
        return
      skip x, SkipCond
    while x.hasMore:
      if x.isStringLit:
        let name = pool.strings[x.strId]
        let src = resolveFile(c.config.paths, current.files[current.active].nimFile, name)
        if semos.fileExists(src):
          let exeName = splitFile(name).name
          current.plugins.incl exeName
          if not c.pluginSources.hasKey(exeName):
            c.pluginSources[exeName] = src
      skip x

proc processBuild(c: var DepContext; it: var Cursor; current: Node) =
  it.into:  # (build …)
    while it.hasMore:
      assert it.exprKind == TupX
      var x = it
      skip it
      x.into TupX:
        assert x.isStringLit
        let typ = pool.strings[x.strId]
        inc x
        assert x.isStringLit
        let path = pool.strings[x.strId]
        inc x
        assert x.isStringLit
        let args = pool.strings[x.strId]
        inc x
        var linkFlags = ""        # optional 4th field (`.build` per-file link flags)
        if x.isStringLit:
          linkFlags = pool.strings[x.strId]
          inc x
        while x.hasMore: skip x
        if typ in ["C", "ObjC", "Cpp", "ObjCpp"]:
          # `.compile` foreign source -> object file, linked into the program.
          # The first field is a C-family language (set by `addBuildTarget`).
          let obj = splitFile(path).name & ".o"
          c.toBuild.add CFile(name: path, obj: obj, customArgs: args)
        else:
          # `{.build(builder, tool, args[, linkflags]).}` — a custom backend routes
          # THIS module's Leng IR through `tool`. The first field is the generic
          # builder command (e.g. `"nimony c"`), distinct from a `.compile`
          # language token above.
          c.backendTools.add BackendTool(builder: typ, toolSrc: path,
            toolName: splitFile(path).name, args: args, modFile: current.files[0],
            linkFlags: linkFlags)

proc processBundle(c: var DepContext; it: var Cursor) =
  ## Read a `(bundle (tup builder tool args)…)` node (`.bundle` pragma): a custom
  ## linker tool that overrides the final link step.
  it.into:  # (bundle …)
    while it.hasMore:
      assert it.exprKind == TupX
      var x = it
      skip it
      x.into TupX:
        assert x.isStringLit
        let builder = pool.strings[x.strId]
        inc x
        assert x.isStringLit
        let path = pool.strings[x.strId]
        inc x
        var args = ""
        if x.isStringLit:
          args = pool.strings[x.strId]
          inc x
        while x.hasMore: skip x
        c.bundles.add Bundle(builder: builder, toolSrc: path,
          toolName: splitFile(path).name, args: args)

proc processDep(c: var DepContext; n: var Cursor; current: Node) =
  case stmtKind(n)
  of ImportS:
    processImport c, n, current
  of IncludeS:
    assert not c.isGeneratingFinal
    processInclude c, n, current
  of FromimportS, ImportexceptS:
    processSingleImport c, n, current
  of ExportS:
    discard "ignore `export` statement"
    skip n
  of NoStmt:
    if n.cursorTagId == TagId(BuildIdx):
      processBuild c, n, current
    elif n.cursorTagId == TagId(BundleIdx):
      processBundle c, n
    elif n.cursorTagId == TagId(PluginP):
      processPlugin c, n, current
    elif n.cursorTagId == TagId(PassLP):
      n.into:  # (passL …)
        while n.hasMore:
          assert n.isStringLit
          # A single `{.passL.}` value may hold several flags (e.g.
          # `-framework Foundation`). nifmake quotes each StringLit as ONE argv
          # token, so split into whitespace-separated flags here — otherwise the
          # linker sees `-framework Foundation` as a single unknown argument.
          for flag in splitWhitespace(pool.strings[n.strId]):
            c.passL.add flag
          inc n
    elif n.cursorTagId == TagId(PassCP):
      n.into:  # (passC …)
        while n.hasMore:
          assert n.isStringLit
          for flag in splitWhitespace(pool.strings[n.strId]):
            c.passC.add flag
          inc n
    else:
      skip n
  else:
    #echo "IGNORING ", toString(n, false)
    skip n

proc processDeps(c: var DepContext; n: Cursor; current: Node) =
  var n = n
  if n.isTagLit and globalTags.tags[n.cursorTagId] == "stmts":
    n.into:
      while n.hasMore:
        processDep c, n, current

proc getLastModTime(path: string): int64 =
  ## `vfsMtime` raises on transient I/O errors (and on a missing file). We
  ## only use the result for staleness comparisons, so any failure should fall
  ## through to "rebuild needed" — returning -1 makes that automatic: `-1 > anything`
  ## is false (so we don't skip rebuilds), and `-1 == -1` (when both paths
  ## fail) is also not `>`, so we still rebuild.
  ## Through `vfsMtime`, so an artifact the store holds answers with its
  ## generation instead of with a stat of a disk copy that may not exist.
  try:
    result = vfsMtime(path)
  except:
    result = -1'i64

proc execNifler(c: var DepContext; f: FilePair) =
  # File can be a .nif file, if so, we don't need to run nifler.
  if f.nimFile.endsWith(".nif"):
    return
  let preserveDocs = c.cmd == DoDoc
  let output = c.config.parsedFile(f, preserveDocs)
  let depsFile = c.config.depsFile(f, preserveDocs)
  let srcTime = getLastModTime(f.nimFile)
  if not c.forceRebuild and vfsExists(output) and
      semos.fileExists(f.nimFile) and getLastModTime(output) > srcTime and
      vfsExists(depsFile) and getLastModTime(depsFile) > srcTime:
    discard "nothing to do"
  else:
    let docsFlag = if preserveDocs: " --docs" else: ""
    let cmd = quoteShell(c.nifler) & " --portablePaths --deps" & docsFlag & " parse " &
      quoteShell(f.nimFile) & " " & quoteShell(output)
    exec cmd

proc importSystem(c: var DepContext; current: Node) =
  let p = c.toPair(stdlibFile("std/system.nim"))
  var existingNode = c.processedModules.getOrDefault(p.modname, -1)
  if existingNode == -1:
    #echo "NIFLING ", p.nimFile, " -> ", c.config.parsedFile(p)
    execNifler c, p
    var imported = Node(files: @[p], id: c.nodes.len, parent: current.id, isSystem: true)
    c.nodes.add imported
    c.processedModules[p.modname] = imported.id
    traverseDeps c, p, imported
    existingNode = imported.id
  current.deps.add existingNode

proc loadDepsFile(depsFile: string): TokenBuf =
  var r = rd.open(depsFile)
  result = createTokenBuf()
  parse(r, result)
  rd.close(r)

proc processFileDeps(c: var DepContext; p: FilePair; current: Node) =
  ## Reads the `(dependency …)` list out of the `.s.deps.nif` the previous
  ## build's nimsem wrote (nim-lang/nimony#1378). The classic depfile pattern:
  ## the first build has nothing to read and runs regardless, every later one
  ## is exact. Nothing else in that file is looked at: its imports are last
  ## build's, and the caller has just read the current ones from nifler.
  let depsFile = c.config.deps2File(p)
  if vfsExists(depsFile):
    var buf = loadDepsFile(depsFile)
    var n = beginRead(buf)
    if n.isTagLit and globalTags.tags[n.cursorTagId] == "stmts":
      n.into:
        while n.hasMore:
          if n.cursorTagId == TagId(DependencyIdx):
            n.into:
              while n.hasMore:
                assert n.isStringLit
                current.fileDeps.add pool.strings[n.strId]
                inc n
          else:
            skip n

proc traverseDeps(c: var DepContext; p: FilePair; current: Node) =
  let depsFile: string
  if not c.isGeneratingFinal:
    execNifler c, p
    depsFile = c.config.depsFile(p, c.cmd == DoDoc)
    processFileDeps c, p, current
  else:
    depsFile = c.config.deps2File(p)

  var buf = loadDepsFile(depsFile)
  processDeps c, beginRead(buf), current
  if {SkipSystem, IsSystem} * c.moduleFlags == {} and not current.isSystem:
    importSystem c, current

proc propagatePlugins(c: var DepContext) =
  ## A plugin declared in module A runs whenever a module importing A is
  ## semchecked (a `.plugin` template of A expands at its call site in B), so
  ## a nimsem run needs the plugins of its whole import closure. A fixpoint
  ## over `deps` rather than a DFS: cyclic modules make the graph a general
  ## digraph and it is small.
  var changed = true
  while changed:
    changed = false
    for v in c.nodes:
      for d in v.deps:
        if d == v.id: continue   # never iterate a set while growing it
        for p in c.nodes[d].plugins:
          if not v.plugins.containsOrIncl(p):
            changed = true

proc rootPath(c: DepContext): string =
  # XXX: Relative paths in build files are relative to current working directory, not the location of the build file.
  result = absoluteParentDir(c.rootNode.files[0].nimFile)
  result = onRaiseQuit relativePath(result, onRaiseQuit os.getCurrentDir())

proc sharedObjDir(): string =
  ## Project-wide cache for object files produced from `{.build("C", ...).}`
  ## pragmas (currently just `vendor/mimalloc/src/static.c`). These TUs don't
  ## depend on per-project state, so compiling them once and reusing the .o
  ## across nimcaches saves ~4-5 s per cold build on Windows.
  result = getCacheDir("nimony") / "nimcache_static"

proc sharedObjFile(cfile: CFile): string =
  sharedObjDir() / cfile.obj

proc emitFrontendArgs(b: var Builder; baseDir, commandLineArgs: string) =
  ## Emit the shared `--base:` plus the forwarded `commandLineArgs` for a
  ## frontend tool command (`nimsem`/`idetools`), de-duplicating as we go.
  ## `--base:` is always written explicitly from `baseDir`, so any `--base:`
  ## already present in `commandLineArgs` is dropped, and other exact-duplicate
  ## args are collapsed. This matters for the nested sub-compiles that
  ## compile-time evaluation spawns (`semos.runProgram`/`prepareEval`,
  ## `macro_plugin`): those thread the outer `--base:`/`--nimcache:` back in via
  ## `commandLineArgs`, which would otherwise emit `--base:X --base:X …
  ## --nimcache:X … --nimcache:X` — an argv that no longer matches the outer
  ## build's command for the same module.
  var seen: seq[string] = @[]
  if baseDir.len > 0:
    let baseArg = "--base:" & quoteShell(baseDir)
    b.addStrLit baseArg
    seen.add baseArg
  for arg in commandLineArgs.split(' '):
    if arg.len > 0 and not arg.startsWith("--base:") and arg notin seen:
      b.addStrLit arg
      seen.add arg

proc defineNiflerCmd(b: var Builder; nifler: string; preserveDocs = false) =
  b.withTree "cmd":
    b.addSymbolDef "nifler"
    b.addStrLit nifler
    b.addStrLit "--portablePaths"
    b.addStrLit "--deps"
    if preserveDocs:
      b.addStrLit "--docs"
    b.addStrLit "parse"
    b.addKeyw "input"
    b.addKeyw "output"

proc defineHexerCmds(b: var Builder; hexer: string; bits: int; bigEndian: bool;
                     targetOS: TSystemOS; checkFlags: string; native: bool) =
  let cpuFlag = if bigEndian: "--cpu:be" else: "--cpu:le"
  b.withTree "cmd":
    b.addSymbolDef "hexer"
    b.addStrLit hexer
    b.addStrLit "c"
    b.addStrLit "--bits:" & $bits
    b.addStrLit cpuFlag
    # `genMainProc` shapes the entry point per OS: a Windows process receives
    # no argc/argv/envp, so `main` takes none there.
    b.addStrLit "--os:" & platform.OS[targetOS].name
    if native: b.addStrLit "--native"
    # Forward the active check modes so nifcgen injects only the requested
    # runtime checks (e.g. `--boundchecks:off` ⇒ no `nimUcheckB` in `(at …)`).
    # A bare `--flags` means "no checks" (e.g. `-d:danger`): with a trailing
    # `--flags:` parseopt would consume the next argument as its value.
    b.addStrLit (if checkFlags.len > 0: "--flags:" & checkFlags else: "--flags")
    b.addKeyw "args"
    b.withTree "input":
      b.addIntLit 0

  b.withTree "cmd":
    b.addSymbolDef "dce"
    b.addStrLit hexer
    b.addStrLit "d"
    b.addStrLit "--bits:" & $bits
    b.addStrLit cpuFlag
    b.addKeyw "args"
    b.withTree "input":
      b.addIntLit 0
      b.addIntLit -1  # all inputs

  # Split DCE: liveness phase (single, fast) + per-module emit (parallel).
  # `dceLive` reads every module's .dce.nif analysis, computes the global
  # live set + generic-resolve table, and writes one `<M>.live.nif` per module
  # plus the whole-program `<main>.all.live.nif` (`--split`, JIT_IMPL.md P0c).
  # Only output 0 -- the whole-program file -- reaches argv; the per-module
  # files are declared as outputs so that nifmake knows which node produces
  # them (and rebuilds when one is missing), and `hexer dl` derives their paths
  # from `--split:<dir>` itself.
  b.withTree "cmd":
    b.addSymbolDef "dceLive"
    b.addStrLit hexer
    b.addStrLit "dl"
    b.addStrLit "--bits:" & $bits
    b.addStrLit cpuFlag
    b.addKeyw "args"
    b.withTree "input":
      b.addIntLit 0
      b.addIntLit -1
    b.withTree "output":
      b.addIntLit 0
      b.addIntLit 0

  # `dceEmit` rewrites one .x.nif into .c.nif using that module's own
  # .live.nif. Independent across modules, so nifmake can run them in parallel.
  # Output path is derived from `--outdir` + input modname (mirrors how
  # `hexer c` derives outputs), so no explicit output slot here.
  b.withTree "cmd":
    b.addSymbolDef "dceEmit"
    b.addStrLit hexer
    b.addStrLit "de"
    b.addStrLit "--bits:" & $bits
    b.addStrLit cpuFlag
    b.addKeyw "args"
    b.withTree "input":
      b.addIntLit 0  # M.x.nif
      b.addIntLit 1  # M.live.nif

proc generateDocBuildFile(c: DepContext): string =
  ## Doc backend: each per-module `dagon module` rule produces both a `.html`
  ## and a `.docidx` sidecar; the trailing `dagon link` task gathers all the
  ## sidecars into the global `theindex.html`. The HTML lands at a friendly
  ## directory-mirrored path (`htmldocs/std/system.html` etc.); the `.docidx`
  ## stays under nimcache to avoid user-visible churn.
  result = c.config.nifcachePath / c.rootNode.files[0].modname & ".doc.build.nif"
  var b = nifbuilder.open(result)
  defer: b.close()

  # Slash-normalise so the build file (and the args we pass to dagon) is
  # byte-identical across OSes. `deriveRelpath` does prefix matching on
  # roots, so callers downstream must agree on the separator.
  let projectRoot = toUnixPath(absoluteParentDir(c.rootNode.files[0].nimFile))
  let stdlibRoot = toUnixPath(stdlibDir())
  let rootFlags = "--projectRoot:" & projectRoot & " --stdlibRoot:" & stdlibRoot

  b.addHeader()
  b.withTree "stmts":
    let dagon = findTool("dagon")

    let outdir = docOutDir(c.config)
    b.withTree "cmd":
      b.addSymbolDef "dagon"
      b.addStrLit dagon
      b.addStrLit "--projectRoot:" & projectRoot
      b.addStrLit "--stdlibRoot:" & stdlibRoot
      b.addStrLit "--outdir:" & outdir
      b.addStrLit "module"
      b.addKeyw "args"

    b.withTree "cmd":
      b.addSymbolDef "doclink"
      b.addStrLit dagon
      b.addStrLit "--projectRoot:" & projectRoot
      b.addStrLit "--stdlibRoot:" & stdlibRoot
      b.addStrLit "--outdir:" & outdir
      b.addStrLit "link"
      b.addKeyw "args"

    for v in c.nodes:
      if v.plugin.len > 0: continue
      let semFile = c.config.semmedFile(v.files[0], v.plugin, preserveDocs = true)
      let htmlOut = c.config.docFile(v.files[0], projectRoot, stdlibRoot)
      let idxOut = c.config.docIdxFile(v.files[0])
      b.withTree "do":
        b.addIdent "dagon"
        b.withTree "args":
          b.addStrLit semFile
          b.addStrLit htmlOut
          b.addStrLit idxOut
        b.withTree "input":
          b.addStrLit semFile
        b.withTree "output":
          b.addStrLit htmlOut
        b.withTree "output":
          b.addStrLit idxOut

    let indexOut = c.config.indexHtmlFile()
    b.withTree "do":
      b.addIdent "doclink"
      b.withTree "args":
        b.addStrLit indexOut
        for v in c.nodes:
          if v.plugin.len > 0: continue
          b.addStrLit c.config.docIdxFile(v.files[0])
      for v in c.nodes:
        if v.plugin.len > 0: continue
        b.withTree "input":
          b.addStrLit c.config.docIdxFile(v.files[0])
      b.withTree "output":
        b.addStrLit indexOut
  discard rootFlags  # silence unused warning if logging is later removed

proc wantTool(name, src, builder, nifcachePath: string;
              toolExe, toolBuild, toolBuilderCmd, builderCmdName: var Table[string, string]) =
  ## Register a backend tool (a routing tool or a custom linker) for build/command
  ## emission: reuse a prebuilt `bin/` copy if present, else compile it from
  ## source on demand. Mutates the shared tables `generateFinalBuildFile` walks to
  ## emit the builder commands, routing commands, and tool-build nodes.
  if toolExe.hasKey(name): return
  let found = findTool(name)
  if semos.fileExists(found):
    toolExe[name] = found                      # prebuilt / known -> use as-is
  else:
    toolExe[name] = nifcachePath / name.addFileExt(ExeExt)
    toolBuild[name] = src
    toolBuilderCmd[name] = builder
    if not builderCmdName.hasKey(builder):
      builderCmdName[builder] = "builderCmd" & $builderCmdName.len

type
  ManifestFile = object
    ## One `(file …)` entry of the link manifest. `flags` are link flags scoped to
    ## THIS file (from a `.build` module's 4th slot), passed to the linker next to
    ## it — distinct from the manifest's global `(flags …)` (`passL`).
    path: string
    kind: string          ## "obj" | "artifact"
    flags: seq[string]

proc writeLinkManifest(path, exe, apptype: string;
                       files: seq[ManifestFile]; flags: seq[string]): string =
  ## Write the manifest NIF a linker (the default `niflink`, or a `{.bundle.}`
  ## tool) consumes: every project artifact (objects + routed backend outputs)
  ## with optional per-file link flags, the app-type, and the global link flags.
  ## The linker reads this and links/bundles/filters as it sees fit (e.g. link the
  ## `obj`s, embed or ignore the backend `artifact`s).
  ##
  ## Written `OnlyIfChanged`: the manifest is an input of the link nifmake node,
  ## so rewriting it with a fresh mtime on every `nimony c` would re-fire the
  ## link even on a no-op build. Preserving the mtime when the bytes are
  ## identical keeps the backend incremental.
  var b = nifbuilder.open(path, writeMode = OnlyIfChanged)
  b.addHeader()
  b.withTree "link":
    b.withTree "apptype":
      b.addStrLit apptype
    b.withTree "output":
      b.addStrLit exe
    for f in files:
      b.withTree "file":
        b.addStrLit f.path
        b.withTree "kind":
          b.addStrLit f.kind
        if f.flags.len > 0:
          b.withTree "flags":
            for fl in f.flags:
              b.addStrLit fl
    if flags.len > 0:
      b.withTree "flags":
        for f in flags:
          b.addStrLit f
  b.close()
  result = path

proc addInlineSourceInputs(b: var Builder; c: DepContext; v: Node; backend: string) =
  ## Declare the `.c.nif` of every module `v` imports as an input of `v`'s
  ## codegen node.
  ##
  ## All three consumers of a `.c.nif` -- `lengc`, `arkham` and Shoggoth's
  ## `optimize` -- resolve foreign symbols by loading the *callee* module's
  ## `.c.nif` on demand, and splice imported `.inline` bodies out of it. That
  ## makes those files real inputs: nifmake decides whether to rerun a node
  ## from its declared inputs, so without these edges an edit that only
  ## changes a callee leaves every importer's already-generated code in place,
  ## with a stale copy of the body spliced into it. The result is a link error
  ## when the edit renames a symbol the splice references, and a silently
  ## wrong binary when it does not (nim-lang/nimony#1897).
  ##
  ## Only input[0] reaches the tool's command line, so the extra inputs cost
  ## nothing but the ordering and the freshness check.
  var seen = initHashSet[string]()
  for depIdx in v.deps:
    let depNif = c.config.lengcFile(c.nodes[depIdx].files[0], backend)
    if not seen.containsOrIncl(depNif):
      b.withTree "input":
        b.addStrLit depNif

proc ccCmdTokens(c: DepContext; passC: string; nativeSysLink: bool;
                 sysLinker: string): seq[string] =
  ## The leading, invocation-independent tokens of the `cc` command: the driver
  ## plus every flag that does not depend on which file is being compiled.
  ## `generateFinalBuildFile` emits them into the `(cmd :cc …)` tree and
  ## `fillObjectCache` folds them into the object cache key, so the key can
  ## never disagree with the command it stands for.
  result = @[]
  var ccProgram = c.config.cc
  if c.config.backend == backendLLVM:
    ccProgram = "clang"
  elif nativeSysLink:
    # Compiles the `.compile`d TUs (e.g. Objective-C `.m`); same driver
    # that links them, so the toolchain/ABI matches.
    ccProgram = sysLinker
  result.add ccProgram
  result.add "-c"
  # Suppress visibility-attribute warnings from mimalloc etc. (GCC/Clang)
  result.add "-Wno-attributes"
  # gcc-14 on arm64/Linux emits a stringop-overflow false positive
  # ("writing 8 bytes into a region of size 0 ... destination object is
  # likely at address zero") from inlined refcount updates on paths the
  # optimizer itself proved unreachable. Same policy as #2168: silence
  # GCC's overreach instead of contorting the codegen. Real GCC only:
  # clang has no such warning name and would spam
  # `-Wunknown-warning-option` into every tracked test output — and on
  # macOS `gcc` IS clang, so gate on the target OS as well.
  if extractCCKey(ccProgram) != "clang" and
      c.config.targetOS notin {osMacosx, osIos}:
    result.add "-Wno-stringop-overflow"
  # Note on TLS for clang/Windows: clang emits native PE TLS by default,
  # which is what we want — `__thread` access compiles to a single
  # `gs:0x58` load instead of a `__emutls_get_address` call. ld.bfd
  # (mingw-w64's default linker) mishandles this and produces binaries
  # that segfault on first TLS access; we paper over that at link time
  # by switching to LLD, see the link cmd below. No `-femulated-tls`
  # here.
  # Add -fPIC for shared libraries
  if c.config.appType == appLib:
    result.add "-fPIC"
  # Optimization level. Even the default ("debug") gets -O1: in
  # practice it produces code that's just as easy to step through
  # as -O0, while letting the C compiler skip the truly silly
  # codegen patterns (per-statement spills, dead stores, etc.).
  case c.config.optLevel
  of optDebug: result.add "-O1"
  of optNone:  result.add "-O0"
  of optSize:  result.add "-Os"
  of optSpeed: result.add "-O3"
  if passC.len > 0:
    for arg in passC.split(' '):
      if arg.len > 0:
        result.add arg
  for i in c.passC:
    result.add i
  if c.config.backend == backendC:
    result.add "-I" & rootPath(c)

type
  FinalPhase = enum
    ## Which slice of the backend build graph `generateFinalBuildFile` emits.
    fpWhole    ## everything, in one graph: what every ordinary build uses
    fpLive     ## hexer + `dce` + `dceLive` only; stops before `dceEmit`, so the
               ## shared `<main>.live.nif` exists when the NEXT graph is emitted
               ## and the per-module `.c.nif` cache can be resolved from it
    fpAnalysis ## the same plus `dceEmit`; stops before codegen, so the `.c.nif`
               ## files exist when the third graph is emitted
    fpCodegen  ## the whole graph again, now with the object cache resolved

proc ocacheDir(config: NifConfig): string =
  ## The content-addressed object cache of the compile-time-eval sub-programs.
  ## It lives *inside* the build cache, so `--nimcache:<dir>` scopes it and
  ## deleting `nimcache/` (`hastur clean`) is all the eviction there is.
  config.nifcachePath / "ocache"

proc ocacheBase(c: DepContext; f: FilePair): string =
  ## `<nimcache>/ocache/<hash>` for a module whose object is cached, else "".
  c.ocache.getOrDefault(f.modname, "")

proc ocacheHitFor(c: DepContext; f: FilePair): bool =
  ## True when this module's object is already in the cache. Its `lengc` and
  ## `cc` nodes are then not emitted at all: the path is content-addressed, so
  ## an existing entry IS the right object, and nifmake -- which decides
  ## staleness from mtimes -- would otherwise rebuild it on every sub-program
  ## (the freshly written `.c.nif` is always newer than a cached object).
  c.ocacheHit.contains(f.modname)

proc objFileOf(c: DepContext; f: FilePair; backend: string): string =
  ## On a cache hit the link consumes the shared object directly. On a miss the
  ## module is compiled to its usual place and published into the cache
  ## afterwards (`publishObjectCache`), so no build tool ever writes into
  ## `ocache/` -- see the concurrency note there.
  if ocacheHitFor(c, f): ocacheBase(c, f) & ".o"
  else: c.config.objFile(f, backend)

proc fillObjectCache(c: var DepContext; backend, commandLineArgsLengc, passC: string) =
  ## Give every non-main module of a compile-time-eval sub-program a
  ## content-addressed `.c`/`.o` basename under `<nimcache>/ocache/`.
  ##
  ## This runs between the two backend graphs, so the `fpAnalysis` graph has
  ## just written every `.c.nif` and the digest can cover the actual Leng IR
  ## instead of the inputs it was derived from. That distinction is the whole
  ## point: the DCE live set depends on the main module, so two sub-programs
  ## agree on a module's object exactly when they agree on its `.c.nif`, and
  ## the inputs cannot tell us that.
  ##
  ## The main module (`c.nodes[0]`) is never cached: a sub-program's main
  ## suffix is a checksum of the evaluated expression, so its object is unique
  ## by construction.
  let dir = ocacheDir(c.config)
  onRaiseQuit createDir(path(dir))
  # Everything that is the same for every module of this build: the codegen
  # and cc command lines, and a stamp of the tools that produce the artifacts.
  var common = "lengc\n" & $c.config.backend & "\n" & $c.config.bits & "\n" &
               commandLineArgsLengc & "\ncc\n"
  # The very tokens the `(cmd :cc …)` tree is emitted from. A compile-time-eval
  # sub-program is always the plain C backend with no `.compile`d TUs, so the
  # `nativeSysLink` driver override cannot apply here.
  for tok in ccCmdTokens(c, passC, false, ""):
    common.add tok
    common.add "\n"
  common.add "tools\n"
  common.add $getLastModTime(findTool("lengc"))
  common.add "\n"
  common.add $getLastModTime(findTool("hexer"))
  common.add "\n"
  # The C compiler too: `ccCmdTokens[0]` names it, but a driver upgrade behind
  # the same name must not serve objects compiled by the old one.
  common.add $getLastModTime(findExe(ccCmdTokens(c, passC, false, "")[0]))
  common.add "\n"
  # Every module's Leng IR appears in its own key and in the key of everything
  # that imports it, so digest each file once rather than re-reading it per
  # importer.
  var digests = initTable[string, string]()
  for i in 0 ..< c.nodes.len:
    let p = c.config.lengcFile(c.nodes[i].files[0], backend)
    if not digests.hasKey(p):
      digests[p] = computeChecksum(vfsRead(p))
  for i in 1 ..< c.nodes.len:
    let v = c.nodes[i]
    # The inputs of this module's `lengc` node: its own Leng IR plus every
    # imported module's, out of which lengc splices `.inline` bodies (see
    # `addInlineSourceInputs`). All of them shape the generated `.c`.
    var inputs = @[c.config.lengcFile(v.files[0], backend)]
    for depIdx in v.deps:
      inputs.add c.config.lengcFile(c.nodes[depIdx].files[0], backend)
    var key = common
    var seen = initHashSet[string]()
    for f in inputs:
      if not seen.containsOrIncl(f):
        key.add splitModulePath(f).name
        key.add " "
        key.add digests.getOrDefault(f, "")
        key.add "\n"
    let base = dir / computeChecksum(key)
    c.ocache[v.files[0].modname] = base
    if vfsExists(base & ".o"):
      c.ocacheHit.incl v.files[0].modname

proc publishObjectCache(c: DepContext; backend: string) =
  ## Copy the objects this build had to compile into the content-addressed
  ## cache, together with the C they were compiled from.
  ##
  ## nimony publishes rather than letting `cc` write into `ocache/` directly:
  ## sub-compiles of the same outer build run concurrently, several of them can
  ## land on one key, and `vfsWrite` goes through a temp file and an atomic
  ## rename -- so a reader never sees a half-written object. The `.c` is
  ## written first, so an entry that has an object also has its source.
  for i in 1 ..< c.nodes.len:
    let f = c.nodes[i].files[0]
    let base = ocacheBase(c, f)
    if base.len == 0 or c.ocacheHit.contains(f.modname): continue
    let obj = c.config.objFile(f, backend)
    let src = c.config.genFile(f, backend)
    if not vfsExists(obj) or not vfsExists(src): continue
    try:
      vfsWrite(base & ".c", vfsRead(src))
      vfsWrite(base & ".o", vfsRead(obj))
    except:
      discard  # the only consequence is a miss next time

# ── A2c: the content-addressed `.c.nif` cache ───────────────────────────────
#
# `dceEmit` rewrites one module's `.x.nif` into the `.c.nif` of ONE program,
# because the live set it prunes against is the program's. Every compile-time
# evaluation of one compile is a different program, so the seven stdlib modules
# of `std/writenif`'s closure are re-emitted per sub-program -- measured on
# `tests/nimony/consteval/tmyops.nim`: 35 `dceEmit` runs producing 12 distinct
# files, 9.6 ms per sub-program of which 6.3 ms is re-parsing `system.x.nif`.
#
# What a non-main module's `.c.nif` is a function of is exactly the two inputs
# of its `dceEmit` node: its own `.x.nif`, which is program-INDEPENDENT (it
# lives at the top of the nimcache and every sub-program shares it), and the
# shared `<main>.live.nif`. And `.live.nif` is already partitioned by module:
# `(live (mod "<suffix>" <syms…>) …)` plus one global `(resolved (kv …) …)`
# table naming the owner of every generic instance.
#
# So the key is the module's own slice of that file. The `resolved` entries
# owned by the MAIN module are left out, and that is what makes the key stable
# across sub-programs: they are the instances that only the snippet offers
# (P0b's ownership rule already guarantees the main module never wins an
# instance some other module also offers), and a stdlib module's `.x.nif` --
# byte-identical from one sub-program to the next -- cannot name a symbol that
# did not exist when it was written. Verified rather than only argued: over
# five sub-programs of `tmyops` the keys partition the 35 emissions into
# exactly the 12 distinct outputs, i.e. no two different `.c.nif` files ever
# share a key, and `tests/ctfe_engine` re-checks that by compiling the corpus
# with `NIMONY_CCACHE=off` and byte-comparing every `.c.nif`.

proc ccacheDir(config: NifConfig): string =
  ## Beside `ocache/`, and with the same lifetime: inside the build cache, so
  ## `--nimcache:<dir>` scopes it and `hastur clean` is the eviction.
  config.nifcachePath / "ccache"

proc ccacheEnabled(): bool =
  ## `NIMONY_CCACHE=off` turns the cache off without a flag, the way
  ## `NIMONY_CTFE_ENGINE` turns the engine off: a flag would be spliced into the
  ## `*.build.nif` and the two settings would stop emitting identical bytes.
  ## A nimony-built compiler has no environment API and simply caches.
  when defined(nimony):
    true
  else:
    getEnv("NIMONY_CCACHE") != "off"

proc xNifDigest(dir, xfile, modname: string): string =
  ## The digest of a module's `.x.nif`, memoized beside the cache.
  ##
  ## It has to be a digest and not a stamp: the entry NAME is what makes the
  ## cache shareable, and two nimcaches must agree on it or an artifact
  ## comparison between them (`tests/nifcache`) sees the same file under two
  ## names. But `system.x.nif` is 1.1 MB and hashing it costs more than the
  ## `dceEmit` this cache exists to avoid -- so the digest is computed once per
  ## nimcache and remembered in a `<modname>.xdig` sidecar under the mtime it
  ## was computed for. The sidecar is not a `.nif`, so it is not an artifact.
  let sidecar = dir / modname & ".xdig"
  let stamp = $getLastModTime(xfile)
  if vfsExists(sidecar):
    try:
      let t = vfsRead(sidecar)
      let nl = t.find('\n')
      if nl > 0 and t.substr(0, nl-1) == stamp:
        return t.substr(nl+1)
    except:
      discard
  result = ""
  try:
    result = computeChecksum(vfsRead(xfile))
    vfsWrite(sidecar, stamp & "\n" & result)
  except:
    result = ""

proc fillCNifCache(c: var DepContext; backend: string) =
  ## Between the `fpLive` and `fpAnalysis` graphs: give every non-main module a
  ## content-addressed `.c.nif` path, and where the cache already holds one,
  ## WRITE it into the sub-program's backend directory.
  ##
  ## Writing rather than omitting the node (which is how `fillObjectCache`
  ## resolves an object) is what keeps this change small: `vfsWrite` goes
  ## through a temp file and a rename, so the `.c.nif` comes out newer than the
  ## `.x.nif` and the `.live.nif` it would have been derived from, and
  ## `nifmake.needsRebuild` skips the `dceEmit` node on its own. The graph the
  ## two modes emit therefore stays byte-identical.
  if not ccacheEnabled(): return
  let backendDir = c.config.nifcachePath / backend
  let dir = ccacheDir(c.config)
  onRaiseQuit createDir(path(dir))
  # Everything that is the same for every module of this build. `dceEmit` is
  # hexer, so its binary's stamp invalidates the whole cache on a rebuild --
  # the same guard `fillObjectCache` puts on the object cache.
  let common = "dceEmit\n" & $c.config.bits & "\n" &
               $ord(c.config.targetCPU) & "\n" & $ord(c.config.targetOS) & "\n" &
               c.config.checkFlags & "\n" &
               $getLastModTime(findTool("hexer")) & "\n"
  for i in 1 ..< c.nodes.len:
    let f = c.nodes[i].files[0]
    let xfile = c.config.hexedFile(f)
    if not vfsExists(xfile): continue
    let xdig = xNifDigest(dir, xfile, f.modname)
    if xdig.len == 0: continue
    var key = common
    key.add "x "
    key.add f.modname
    key.add " "
    key.add xdig
    key.add "\n"
    # The module's OWN live file (P0c): its live set and the resolve entries
    # its `dceEmit` consults, serialized sorted, so its bytes are the exact
    # input `dceEmit` derives the `.c.nif` from. Before P0c this sliced the
    # whole-program file; after it, `<main>.live.nif` is the main module's
    # per-module file, and slicing it gave every stdlib module an empty live
    # set and one key for every sub-program -- a wrong hit surfaced as an
    # unresolved `writeNifInt` in arkham (semantic merge conflict, fixed in
    # the integrator's review).
    let liveFile = backendDir / f.modname & ".live.nif"
    if not vfsExists(liveFile): continue
    var liveDig = ""
    try:
      liveDig = computeChecksum(vfsRead(liveFile))
    except:
      continue
    key.add "live "
    key.add liveDig
    key.add "\n"
    let cached = dir / computeChecksum(key) & ".c.nif"
    c.ccache[f.modname] = cached
    if not vfsExists(cached): continue
    try:
      vfsWrite(c.config.lengcFile(f, backend), vfsRead(cached))
      c.ccacheHit.incl f.modname
    except:
      discard  # a cache that cannot be read is a slower compile, not a failed one

proc publishCNifCache(c: DepContext; backend: string) =
  ## After the `fpAnalysis` graph: offer every freshly emitted `.c.nif` to the
  ## cache. Same publish-don't-write-in-place rule as `publishObjectCache`.
  for i in 1 ..< c.nodes.len:
    let f = c.nodes[i].files[0]
    let cached = c.ccache.getOrDefault(f.modname, "")
    if cached.len == 0 or c.ccacheHit.contains(f.modname): continue
    if vfsExists(cached): continue
    let produced = c.config.lengcFile(f, backend)
    if not vfsExists(produced): continue
    try:
      vfsWrite(cached, vfsRead(produced))
    except:
      discard

proc generateFinalBuildFile(c: DepContext; commandLineArgsLengc: string;
                            passC, passL: string;
                            phase: FinalPhase = fpWhole): string =
  var stem = ".final.build.nif"
  if phase == fpLive: stem = ".final0.build.nif"
  elif phase == fpAnalysis: stem = ".final1.build.nif"
  elif phase == fpCodegen: stem = ".final2.build.nif"
  result = c.config.nifcachePath / c.rootNode.files[0].modname & stem
  var b = nifbuilder.open(result)
  defer: b.close()

  b.addHeader()
  b.withTree "stmts":
    # Command definitions
    let lengc = findTool("lengc")
    let hexer = findTool("hexer")
    # The experimental Shoggoth optimizer runs only when optimization is
    # actually requested (`--opt:speed` / `--opt:size`); default/debug builds
    # are byte-for-byte unaffected.
    let wasm = c.config.backend == backendWasm
    let useOptimizer = c.config.optLevel in {optSpeed, optSize}
    let native = c.config.backend == backendNative
    # A native program that uses the `.compile`/`{.build…}` pragma (in ANY module)
    # is finished by the system linker, so nifasm's relocatable object can be
    # combined with the foreign `.o`s (e.g. Objective-C) and any frameworks. Plain
    # native programs keep the static, libc-free "nifasm is the linker" path.
    # (Written as plain `var`s rather than `and`/`if`-expression `let`s: the
    # self-hosted compiler's initialization analysis can't yet prove the temp
    # such expressions lower to is always assigned.)
    var nativeSysLink = false
    if native and c.toBuild.len > 0: nativeSysLink = true
    # The foreign objects and frameworks need a real driver; clang knows how to
    # compile `.m`/`.c`, pull in libobjc, resolve `-framework`, and supply the crt.
    var sysLinker = c.config.linker
    if sysLinker.len == 0: sysLinker = "clang"
    var shoggoth = ""
    if useOptimizer:
      shoggoth = findTool("shoggoth")

    if wasm:
      # Wasm backend: ithaqua is codegen AND linker in one — it reads the MAIN
      # module's `.c.nif` and pulls every dependent module from disk through
      # the embedded index (whole-program emission), so there is exactly one
      # command and it runs once. Only input[0] reaches its command line.
      b.withTree "cmd":
        b.addSymbolDef "ithaqua"
        b.addStrLit findTool("ithaqua")
        b.withTree "output":
          b.addStrLit "-o:"
        b.withTree "input":
          b.addIntLit 0
          b.addIntLit 0
    elif native:
      # Native backend: arkham (Leng -> typed asm-NIF) replaces lengc. Output is
      # passed as the single token `-o:<path>` (the colon form; `addFilename`
      # concatenates the `-o:` prefix directly onto the output path).
      b.withTree "cmd":
        b.addSymbolDef "arkham"
        b.addStrLit findTool("arkham")
        # Forward the target verbatim — arkham speaks the same platform symbols
        # and errors on an unsupported combination (no silent host fallback).
        b.addStrLit "--os:" & platform.OS[c.config.targetOS].name
        b.addStrLit "--cpu:" & platform.CPU[c.config.targetCPU].name
        # The board, when one was given. A bare-metal image has no OS to ask how
        # much RAM it may have, so the layout file IS that answer — and arkham
        # forwards it into the asm-NIF so nifasm places segments from the same
        # description rather than reading the file a second time.
        if c.config.layoutFile.len > 0:
          b.addStrLit "--layout:" & c.config.layoutFile
        b.withTree "output":
          b.addStrLit "-o:"
        b.addKeyw "input"
    else:
      # Command for lengc (code generation)
      b.withTree "cmd":
        b.addSymbolDef "lengc"
        b.addStrLit lengc
        b.addStrLit $c.config.backend
        b.addStrLit "--compileOnly"
        b.addStrLit "--bits:" & $c.config.bits
        b.addKeyw "args"
        if commandLineArgsLengc.len > 0:
          for arg in commandLineArgsLengc.split(' '):
            if arg.len > 0:
              b.addStrLit arg
        b.addKeyw "input"

    # Command for the tree optimizer: `shoggoth c <input.c.nif> <output.oc.nif>`.
    if useOptimizer:
      b.withTree "cmd":
        b.addSymbolDef "optimize"
        b.addStrLit shoggoth
        b.addStrLit "c"
        let cpuName = platform.CPU[c.config.targetCPU].name
        if native and cpuName in ["arm64", "amd64"]:
          # the 128-bit loop vectorizer: emits (instr ...) rows only the native
          # back ends lower — AArch64 via AdvSIMD, x86-64 via SSE2 — so it stays
          # target-gated. (The flag is part of the command line, so nifmake's
          # cache key separates vectorized .oc.nif files from C-backend ones.)
          # Spelled with a plain local rather than an `if` expression: nimony
          # compiles this file, and its initialization analysis cannot prove a
          # temp bound by a branch expression is initialized here.
          var vecFlag = "--vectorize"
          if cpuName == "amd64": vecFlag = "--vectorize:sse"
          b.addStrLit vecFlag
        b.addKeyw "input"
        b.addKeyw "output"

    # Command for hexer
    defineHexerCmds(b, hexer, c.config.bits, platform.CPU[c.config.targetCPU].endian == bigEndian,
                    c.config.targetOS, c.config.checkFlags, c.config.backend == backendNative)

    # Command for C/LLVM compiler (object files)
    b.withTree "cmd":
      b.addSymbolDef "cc"
      for tok in ccCmdTokens(c, passC, nativeSysLink, sysLinker):
        b.addStrLit tok
      b.addKeyw "args"
      b.addKeyw "input"
      b.addStrLit "-o"
      b.addKeyw "output"

    # Commands for custom backends (`{.build(builder, tool[, args]).}`): each
    # module routes its Leng IR through `tool`, an external program compiled on
    # demand by the *generic* `builder` command (e.g. `"nimony c"`, `"nim c"`,
    # `"nimony c --path:…"`). Nothing about the builder or tool names is
    # hardcoded: the builder's first token is the program (resolved via
    # `findTool`, so `nimony` -> `bin/`, `nim` -> PATH), the rest is passed
    # verbatim, and the tool exe is written via `-o:` (accepted by both nim and
    # nimony). A tool already present in `bin/` (a known name) is used as-is.
    var backendToolExe = initTable[string, string]()      # toolName -> exe path
    var backendToolBuild = initTable[string, string]()    # toolName -> source (only if we build it)
    var backendToolBuilderCmd = initTable[string, string]() # toolName -> builder command string
    var builderCmdName = initTable[string, string]()      # builder string -> nifmake cmd name
    var customLinkerName = ""   # "" = no custom linker; else overrides the link step
    var customLinkerArgs = ""
    for bt in c.backendTools:
      wantTool(bt.toolName, bt.toolSrc, bt.builder, c.config.nifcachePath,
               backendToolExe, backendToolBuild, backendToolBuilderCmd, builderCmdName)
    # A `{.bundle.}` module overrides the link step; the first one wins.
    for bn in c.bundles:
      if customLinkerName.len == 0:
        customLinkerName = bn.toolName
        customLinkerArgs = bn.args
        wantTool(bn.toolName, bn.toolSrc, bn.builder, c.config.nifcachePath,
                 backendToolExe, backendToolBuild, backendToolBuilderCmd, builderCmdName)
    if c.backendTools.len > 0 or c.bundles.len > 0:
      # One build command per distinct builder string: `<prog> <rest…> -o:<exe> <src>`.
      for builder, cmdName in builderCmdName:
        let toks = builder.splitWhitespace
        b.withTree "cmd":
          b.addSymbolDef cmdName
          b.addStrLit toks[0]                 # program; expandCommand resolves via findTool
          for i in 1 ..< toks.len:            # subcommand + flags, verbatim
            b.addStrLit toks[i]
          b.withTree "output":
            b.addStrLit "-o:"
          b.addKeyw "input"
      # Routing command per distinct tool: `<toolExe> <args> <module.c.nif> <out>`.
      # The tool exe is also a `(do …)` input (so nifmake builds it first), but is
      # referenced by index `(input 0 0)` so only the Leng IR reaches the cmdline.
      for tn, exe in backendToolExe:
        b.withTree "cmd":
          b.addSymbolDef tn
          b.addStrLit exe
          b.addKeyw "args"
          b.withTree "input":
            b.addIntLit 0
            b.addIntLit 0
          b.addKeyw "output"

    # Command for linking/archiving
    if c.cmd in {DoCompile, DoRun} and nativeSysLink:
      # Two commands: nifasm emits a relocatable object (it still bundles every
      # module's `.asm.nif`, reachable from the main one via `(input 0 0)`), and
      # the system linker combines that object with the `.compile`d foreign `.o`s
      # and any `-framework`/`-l` flags (passL) into the final executable.
      b.withTree "cmd":
        b.addSymbolDef "nifasmObj"
        b.addStrLit findTool("nifasm")
        b.addStrLit "--emit-obj"
        b.withTree "output":
          b.addStrLit "-o:"
        b.withTree "input":
          b.addIntLit 0
          b.addIntLit 0  # only the main module's .asm.nif on the command line
      b.withTree "cmd":
        b.addSymbolDef "link"
        b.addStrLit sysLinker
        b.addStrLit "-o"
        b.addKeyw "output"
        b.withTree "input":
          b.addIntLit 0
          b.addIntLit -1  # nifasm object + every `.compile` object
        b.withTree "argsext":
          b.addStrLit ".linker.args"
        if passL.len > 0:
          for arg in passL.split(' '):
            if arg.len > 0:
              b.addStrLit arg
        for i in c.passL:
          b.addStrLit i
    elif c.cmd in {DoCompile, DoRun} and native:
      # nifasm is the native linker: it takes the *main* module's `.asm.nif`
      # (`(input 0 0)`) and pulls the dependent `.asm.nif` modules from disk by
      # suffix via the shared NIF module loader. `-o:` is the colon form.
      b.withTree "cmd":
        b.addSymbolDef "link"
        b.addStrLit findTool("nifasm")
        b.withTree "output":
          b.addStrLit "-o:"
        b.withTree "input":
          b.addIntLit 0
          b.addIntLit 0  # only the main module's .asm.nif on the command line
    elif c.cmd in {DoCompile, DoRun}:
      # Plain C/LLVM backend: `niflink` is the default linker. It reads the link
      # manifest (input 0) — every object, the app-type, and the link flags — and
      # compiles/links/archives itself, so the old per-app-type `ar` / `-shared` /
      # exe branches collapse into this one node. (A `{.build(…, linker).}` module
      # overrides it with its own tool.)
      b.withTree "cmd":
        b.addSymbolDef "link"
        b.addStrLit findTool("niflink")
        b.withTree "input":
          b.addIntLit 0
          b.addIntLit 0  # only the manifest reaches niflink's command line
        b.addKeyw "output"

    # Build rules
    if c.cmd in {DoCompile, DoRun}:
      let backend = c.config.backendDirName(c.rootNode.files[0])
      let backendDir = c.config.nifcachePath / backend
      # The whole-program live file. It is the `dceLive` node's ALWAYS-written
      # output and nothing reads it during a build: it exists so the node has a
      # staleness anchor, because all of its per-module outputs are written
      # `OnlyIfChanged` and a run that changed none of them would otherwise
      # leave every output older than the input that woke it (see
      # `dag.needsRebuild`'s "freshest output" comment). `.all.` keeps it apart
      # from the main module's own `<main>.live.nif`.
      let liveFile = backendDir / c.rootNode.files[0].modname & ".all.live.nif"

      # Split DCE — phase 1: collect every module's .dce.nif analysis,
      # compute the global live set + generic-instance resolve table,
      # write one <M>.live.nif per module. Single small serial node.
      if phase != fpAnalysis:
        # Not in the second graph either, and for the same reason as hexer
        # above: a repeated node would recompute the live set a second time
        # (its per-module outputs are OnlyIfChanged and would look stale).
        b.withTree "do":
          b.addIdent "dceLive"
          b.withTree "args":
            b.addStrLit "--split:" & backendDir
          for i, n in pairs c.nodes:
            # The .dce.nif sits next to its corresponding .x.nif.
            var dceFile = ""
            if i == 0:
              dceFile = backendDir / n.files[0].modname & ".dce.nif"
            else:
              dceFile = c.config.nifcachePath / n.files[0].modname & ".dce.nif"
            b.withTree "input":
              b.addStrLit dceFile
          b.withTree "output":
            b.addStrLit liveFile
          for n in c.nodes:
            b.withTree "output":
              b.addStrLit backendDir / n.files[0].modname & ".live.nif"

      # Split DCE — phase 2: per-module emit. Each `(do dceEmit ...)` is
      # independent, so nifmake parallelises them across cores. Its live-set
      # input is its OWN module's file: an edit that does not move a module's
      # live set leaves that file's mtime alone, so this node does not re-run
      # and neither do the `lengc`/`cc` nodes below it (JIT_IMPL.md P0c).
      for i, n in pairs c.nodes:
        if phase == fpLive:
          # The live graph stops here: `<main>.live.nif` is all it owes, and
          # `fillCNifCache` needs it before the emit nodes are decided.
          break
        b.withTree "do":
          b.addIdent "dceEmit"
          b.withTree "args":
            b.addStrLit "--outdir:" & backendDir
          b.withTree "input":
            # Root module's .x.nif is backend-specific (--isMain).
            if i == 0:
              b.addStrLit backendDir / n.files[0].modname & ".x.nif"
            else:
              b.addStrLit c.config.hexedFile(n.files[0])
          b.withTree "input":
            b.addStrLit backendDir / n.files[0].modname & ".live.nif"
          b.withTree "output":
            b.addStrLit c.config.lengcFile(n.files[0], backend)

      # Custom-backend nodes: build each tool once (depth 0) — routing tools AND
      # the custom linker (every entry in `backendToolBuild`) — then route every
      # `.build` module's Leng IR through its routing tool (depth 1, parallel).
      # nifmake orders the tool build before its uses via the exe output->input
      # edge.
      for toolName, src in backendToolBuild:
        b.withTree "do":
          # `getOrDefault` (non-raising): every key is guaranteed present (the
          # tool was just registered via `wantTool`), so the `.raises` `[]` —
          # which would escape this proc's `defer` and force it to be `.raises` —
          # is avoided. Same for the other tool-table lookups below.
          b.addIdent builderCmdName.getOrDefault(backendToolBuilderCmd.getOrDefault(toolName))
          b.withTree "input":
            b.addStrLit src
          b.withTree "output":
            b.addStrLit backendToolExe.getOrDefault(toolName)
      for bt in c.backendTools:
        let lengcInput = c.config.lengcFile(bt.modFile, backend)
        let artifact = lengcInput & "." & bt.toolName & ".out.nif"
        b.withTree "do":
          b.addIdent bt.toolName
          b.withTree "args":
            for flag in splitWhitespace(bt.args):
              b.addStrLit flag
          b.withTree "input":
            b.addStrLit lengcInput
          b.withTree "input":
            b.addStrLit backendToolExe.getOrDefault(bt.toolName)
          b.withTree "output":
            b.addStrLit artifact

      # Link executable
      var objFiles = initHashSet[string]()
      if phase in {fpAnalysis, fpLive}:
        # The analysis graph stops after DCE: no codegen, no objects, nothing
        # to link. The object cache is resolved from the `.c.nif` files this
        # graph produces, and the `fpCodegen` graph does the rest.
        discard
      elif wasm:
        b.withTree "do":
          b.addIdent "ithaqua"
          proc wasmInput(c: DepContext; f: FilePair; backend: string; useOptimizer: bool): string =
            # under the optimizer the whole module set switches to `.oc.nif`
            # together — ithaqua derives sibling filenames from the MAIN
            # input's extension, exactly like arkham's native chain.
            if useOptimizer: result = c.config.optimizedFile(f, backend)
            else: result = c.config.lengcFile(f, backend)
          let mainCNif = wasmInput(c, c.rootNode.files[0], backend, useOptimizer)
          b.withTree "input":
            b.addStrLit mainCNif
          objFiles.incl mainCNif
          for v in c.nodes:
            let cn = wasmInput(c, v.files[0], backend, useOptimizer)
            if not objFiles.containsOrIncl(cn):
              b.withTree "input":
                b.addStrLit cn
          b.withTree "output":
            b.addStrLit c.config.wasmFile(c.rootNode.files[0], backend)
      elif customLinkerName.len > 0 or (not native and not nativeSysLink):
        # Manifest-based link. The plain C/LLVM backend links through the default
        # `link` command (== `niflink`); a `{.bundle.}` module overrides it with
        # its own tool. Either way the linker is handed a manifest NIF describing
        # every project artifact + the app-type, and reads only that (`(input 0
        # 0)`); the objects/artifacts are listed as inputs purely to order them
        # before the link runs.
        # Plain `var` rather than an `if`-expression `let`: the self-hosted
        # compiler's initialization analysis can't prove the temp such an
        # expression lowers to is always assigned (see the similar note above).
        var linkNode = "link"
        if customLinkerName.len > 0: linkNode = customLinkerName
        let exe = c.config.exeFile(c.rootNode.files[0], backend)
        var objs: seq[string] = @[]
        if not native:
          # Dedup by path: a `.compile` shared object (e.g. mimalloc's
          # `nimcache_static/static.o`) can be contributed by several modules'
          # `toBuild`, and linking the same `.o` twice yields duplicate-symbol
          # errors. The manifest niflink actually links is built from `objs`, so
          # the dedup must happen here (not only on the DO-node ordering inputs).
          var seenObjs = initHashSet[string]()
          for cfile in c.toBuild:
            let o = sharedObjFile(cfile)
            if not seenObjs.containsOrIncl(o): objs.add o
          for v in c.nodes:
            let o = objFileOf(c, v.files[0], backend)
            if not seenObjs.containsOrIncl(o): objs.add o
        var artifacts: seq[string] = @[]
        for bt in c.backendTools:
          artifacts.add c.config.lengcFile(bt.modFile, backend) & "." & bt.toolName & ".out.nif"
        # Manifest entries: each object plus, for a `.build` module, its 4th-slot
        # per-file link flags scoped to that object; routed backend outputs follow
        # as `artifact` entries (ignored by a plain C linker, embeddable by a
        # custom one).
        var mfiles: seq[ManifestFile] = @[]
        for o in objs:
          var ff: seq[string] = @[]
          for bt in c.backendTools:
            if bt.linkFlags.len > 0 and objFileOf(c, bt.modFile, backend) == o:
              for fl in splitWhitespace(bt.linkFlags): ff.add fl
          mfiles.add ManifestFile(path: o, kind: "obj", flags: ff)
        for a in artifacts:
          mfiles.add ManifestFile(path: a, kind: "artifact", flags: @[])
        var flags: seq[string] = @[]
        if passL.len > 0:
          for f in passL.split(' '):
            if f.len > 0: flags.add f
        for f in c.passL: flags.add f
        let manifest = backendDir / (c.rootNode.files[0].modname & ".linkmanifest.nif")
        discard writeLinkManifest(manifest, exe, $c.config.appType, mfiles, flags)
        b.withTree "do":
          b.addIdent linkNode
          if customLinkerName.len > 0 and customLinkerArgs.len > 0:
            b.withTree "args":
              for a in splitWhitespace(customLinkerArgs):
                b.addStrLit a
          b.withTree "input":                 # input 0: the manifest the linker reads
            b.addStrLit manifest
          for o in objs:                       # ordering: objects must be built first
            if not objFiles.containsOrIncl(o):
              b.withTree "input":
                b.addStrLit o
          for a in artifacts:                  # ordering: routed backend artifacts
            b.withTree "input":
              b.addStrLit a
          if customLinkerName.len > 0:          # ordering: a custom linker is built first
            b.withTree "input":
              b.addStrLit backendToolExe.getOrDefault(customLinkerName)
          b.withTree "output":
            b.addStrLit exe
      elif nativeSysLink:
        # First nifasm bundles every module's `.asm.nif` into one relocatable
        # object (it reads only the main one's path and pulls the rest by suffix;
        # the others are listed purely to order them before nifasm runs).
        let nativeObj = c.config.objFile(c.rootNode.files[0], backend)
        b.withTree "do":
          b.addIdent "nifasmObj"
          var asmInputs = initHashSet[string]()
          let mainAsm = c.config.asmFile(c.rootNode.files[0], backend)
          b.withTree "input":
            b.addStrLit mainAsm
          asmInputs.incl mainAsm
          for v in c.nodes:
            let a = c.config.asmFile(v.files[0], backend)
            if not asmInputs.containsOrIncl(a):
              b.withTree "input":
                b.addStrLit a
          b.withTree "output":
            b.addStrLit nativeObj
        # Then the system linker combines that object with the `.compile` objects.
        b.withTree "do":
          b.addIdent "link"
          b.withTree "input":
            b.addStrLit nativeObj
          objFiles.incl nativeObj
          for cfile in c.toBuild:
            let obj = sharedObjFile(cfile)
            if not objFiles.containsOrIncl(obj):
              b.withTree "input":
                b.addStrLit obj
          b.withTree "output":
            b.addStrLit c.config.exeFile(c.rootNode.files[0], backend)
      else:
        # Native backend (no custom linker): nifasm links from the *main*
        # module's `.asm.nif` (input[0]) and discovers the dependent modules by
        # suffix on disk. List every module's `.asm.nif` as an input (root first)
        # so they are all built before nifasm runs, even though only input[0]
        # reaches its command line (see the `link` cmd's `(input 0 0)`).
        b.withTree "do":
          b.addIdent "link"
          let mainAsm = c.config.asmFile(c.rootNode.files[0], backend)
          b.withTree "input":
            b.addStrLit mainAsm
          objFiles.incl mainAsm
          for v in c.nodes:
            let a = c.config.asmFile(v.files[0], backend)
            if not objFiles.containsOrIncl(a):
              b.withTree "input":
                b.addStrLit a
          b.withTree "output":
            b.addStrLit c.config.exeFile(c.rootNode.files[0], backend)

      objFiles = initHashSet[string]()
      # Build object files from `.compile`d source files with custom args. Outputs
      # land in `<nimony-root>/nimcache_static/` so the same .o is reused across
      # projects — these TUs (mimalloc's `static.c`, or a user's Objective-C
      # source) don't depend on the user's project. A plain native build has no
      # such TUs (arkham/nifasm go straight to machine code); only a native build
      # that uses the `.compile` pragma (`nativeSysLink`) compiles them.
      if (not native) or nativeSysLink:
        for cfile in c.toBuild:
          let obj = sharedObjFile(cfile)
          if not objFiles.containsOrIncl(obj):
            b.withTree "do":
              b.addIdent "cc"
              b.withTree "input":
                b.addStrLit cfile.name
              b.withTree "args":
                # `customArgs` is a free-form string holding several flags
                # (e.g. `-DMI_STATS=1 -I.../mimalloc/include`). nifmake quotes
                # each StringLit as one shell argument, so emit one StringLit
                # per whitespace-separated flag — otherwise the whole string is
                # passed as a single malformed argument and the `-I` is lost.
                for flag in splitWhitespace(cfile.customArgs):
                  b.addStrLit flag
              b.withTree "output":
                b.addStrLit obj

      for i, v in pairs c.nodes:
        if phase notin {fpAnalysis, fpLive} and not native and not wasm and
            not ocacheHitFor(c, v.files[0]):
          let obj = objFileOf(c, v.files[0], backend)
          if not objFiles.containsOrIncl(obj):
            b.withTree "do":
              b.addIdent "cc"
              b.withTree "input":
                b.addStrLit c.config.genFile(v.files[0], backend)
              b.withTree "output":
                b.addStrLit obj

        # Optionally run Shoggoth on the DCE'd `.c.nif`, producing `.oc.nif`;
        # the codegen (lengc or arkham) consumes that. Skipped entirely unless
        # `useOptimizer`, in which case the plain `.c.nif` is read.
        var lengcInput: string
        if useOptimizer:
          let optimized = c.config.optimizedFile(v.files[0], backend)
          b.withTree "do":
            b.addIdent "optimize"
            b.withTree "input":
              b.addStrLit c.config.lengcFile(v.files[0], backend)
            # Shoggoth's inter-module inliner also reads the imported modules'
            # `.c.nif`. Ordering alone would be free (nifmake runs the DAG in
            # depth batches, and every `dceEmit` shares the `.live.nif` input,
            # so those files are all written in the batch before this node's),
            # but they have to be inputs for FRESHNESS too: without the edge a
            # changed callee body leaves this node's output untouched and the
            # splice inside it stale (nim-lang/nimony#1897).
            addInlineSourceInputs(b, c, v, backend)
            b.withTree "output":
              b.addStrLit optimized
          lengcInput = optimized
        else:
          lengcInput = c.config.lengcFile(v.files[0], backend)

        if phase in {fpAnalysis, fpLive} or ocacheHitFor(c, v.files[0]):
          discard  # the analysis graph stops before codegen (see above), and a
                   # module whose object is already cached needs no C at all
        elif wasm:
          discard  # no per-module codegen: ithaqua's single whole-program
                   # node (see "Link executable" above) consumes the .c.nif
        elif native:
          # arkham: per-module Leng -> typed asm-NIF. arkham additionally loads
          # imported modules' `.c.nif` on demand (cross-module type/sig
          # resolution), so list those as dependency inputs to order them before
          # this module's codegen. Only input[0] (this module's lengcInput)
          # reaches arkham's command line (the `arkham` cmd uses `(input)`).
          b.withTree "do":
            b.addIdent "arkham"
            b.withTree "input":
              b.addStrLit lengcInput
            addInlineSourceInputs(b, c, v, backend)
            b.withTree "output":
              b.addStrLit c.config.asmFile(v.files[0], backend)
        else:
          # Build C/LLVM IR files from .c.nif files. lengc splices the bodies
          # of imported `.inline` procs into this translation unit, reading
          # them out of the callee module's `.c.nif` under `--nimcache`, so
          # those files are inputs of this node exactly as they are of
          # `arkham`'s (nim-lang/nimony#1897). Only input[0] (this module's
          # `lengcInput`) reaches lengc's command line (the cmd uses `(input)`).
          b.withTree "do":
            b.addIdent "lengc"
            b.withTree "args":
              b.addStrLit "--nimcache:" & backendDir
            if i == 0:
              b.withTree "args":
                b.addStrLit "--isMain"
            b.withTree "input":
              b.addStrLit lengcInput
            addInlineSourceInputs(b, c, v, backend)
            b.withTree "output":
              b.addStrLit c.config.genFile(v.files[0], backend)

        if phase != fpAnalysis:
          # `fpAnalysis` is the SECOND graph of a compile-time-eval sub-program
          # and emits nothing but `dceEmit`. `fpLive` has just run these nodes,
          # and hexer writes `.x.nif` OnlyIfChanged -- so a node repeated here
          # looks stale to nifmake's mtime rule and runs a second time. On a
          # forced rebuild, where hexer is the phase that is genuinely stale,
          # that was +48 ms per evaluation.
          # Build .x.nif files from .s.nif files via hexer.
          # For the root module (i==0) the output is backend-specific so that
          # its --isMain version does not overwrite the shared .x.nif that other
          # compilations produce when this module is a non-main dependency.
          b.withTree "do":
            b.addIdent "hexer"
            if i == 0:
              b.withTree "args":
                b.addStrLit "--isMain"
              b.withTree "args":
                b.addStrLit "--app:" & $c.config.appType
              b.withTree "args":
                b.addStrLit "--outdir:" & backendDir
            b.withTree "input":
              b.addStrLit c.config.semmedFile(v.files[0], v.plugin)
            # Cross-module hexer dep: imports' `.s.idx.nif` carries both the
            # interface checksum and inline-proc body hashes (see
            # `processForChecksum`'s inline path). Listing imports' `.s.idx.nif`
            # — and *not* the bulkier `.s.nif` — gives finer-grained incremental:
            # a non-inline private body change in import A keeps A's
            # `.s.idx.nif` byte-identical (mtime preserved), so B's hexer
            # doesn't rerun. Same-module `.s.idx.nif` is intentionally omitted
            # — hexer reads its own embedded index out of `.s.nif`.
            var seenImports = initHashSet[string]()
            for depIdx in v.deps:
              let idxFile = c.config.indexFile(c.nodes[depIdx].files[0], c.nodes[depIdx].plugin)
              if not seenImports.containsOrIncl(idxFile):
                b.withTree "input":
                  b.addStrLit idxFile
            b.withTree "output":
              if i == 0:
                b.addStrLit backendDir / v.files[0].modname & ".x.nif"
              else:
                b.addStrLit c.config.hexedFile(v.files[0])
            # `.dce.nif` is emitted alongside `.x.nif` by `bin/hexer c`. It
            # is consumed only by the split-DCE `dceLive` node, but listing
            # it here lets nifmake track it as a real artifact and order
            # `dceLive` after every per-module hexer.
            b.withTree "output":
              if i == 0:
                b.addStrLit backendDir / v.files[0].modname & ".dce.nif"
              else:
                b.addStrLit c.config.nifcachePath / v.files[0].modname & ".dce.nif"

proc cachedConfigFile(config: NifConfig): string =
  config.nifcachePath / "cachedconfigfile.txt"

proc generateSemInstructions(c: DepContext; v: Node; b: var Builder; isMain: bool) =
  b.withTree "do":
    b.addIdent "nimsem"
    b.withTree "args":
      if v.isSystem:
        b.addStrLit "--isSystem"
      elif isMain:
        b.addStrLit "--isMain"
      # Module files are passed as args (primary first, then cyclic members)
      b.addStrLit c.config.parsedFile(v.files[0], c.cmd == DoDoc)
      for idx in v.cyclicFiles:
        b.addStrLit c.config.parsedFile(v.files[idx], c.cmd == DoDoc)
    # Input: parsed file
    var seenDeps = initHashSet[string]()
    for f in v.files:
      let pf = c.config.parsedFile(f, c.cmd == DoDoc)
      if not seenDeps.containsOrIncl(pf):
        b.withTree "input":
          b.addStrLit pf
    # Input: dependencies
    for i in v.deps:
      let idxFile = c.config.indexFile(c.nodes[i].files[0], c.nodes[i].plugin, c.cmd == DoDoc)
      if not seenDeps.containsOrIncl(idxFile):
        b.withTree "input":
          b.addStrLit idxFile
    # Input: the executables of the plugins this module may run. They are
    # outputs of `pluginbuild` nodes, so nifmake builds them first and re-sems
    # the module when one of them changes.
    var plugins: seq[string] = @[]
    for p in v.plugins: plugins.add p
    sort plugins, cmpNames
    for p in plugins:
      b.withTree "input":
        b.addStrLit c.pluginExe(p)
    # Input: the files last build's sem READ — what `plugins.dependsOn`
    # reported and what `slurp` folded. Nothing in the module's own source
    # names them, so without this a changed data file leaves the `.s.nif`
    # looking current.
    var lostFileDep = false
    for f in v.fileDeps:
      if not semos.fileExists(f):
        lostFileDep = true
      elif not seenDeps.containsOrIncl(f):
        b.withTree "input":
          b.addStrLit f
    # Outputs: semmed file and index file for primary module
    let docMode = c.cmd == DoDoc
    if lostFileDep:
      # A deleted file cannot be an input (nifmake wants a file or a rule for
      # each), so the re-sem is forced by removing the output instead. That
      # settles after one build: the re-sem no longer finds the file and so no
      # longer records it.
      vfsRemove(c.config.semmedFile(v.files[0], v.plugin, docMode))
    b.withTree "output":
      b.addStrLit c.config.semmedFile(v.files[0], v.plugin, docMode)
    b.withTree "output":
      b.addStrLit c.config.indexFile(v.files[0], v.plugin, docMode)
    # Outputs for cyclic group members:
    for idx in v.cyclicFiles:
      b.withTree "output":
        b.addStrLit c.config.semmedFile(v.files[idx], v.plugin, docMode)
      b.withTree "output":
        b.addStrLit c.config.indexFile(v.files[idx], v.plugin, docMode)

proc generatePluginSemInstructions(c: DepContext; v: Node; b: var Builder) =
  #[ An import plugin fills `nimcache/<plugin>` for us. It is our job to
  generate index files for all `.nif` files in there. Both the frontend and
  the backend needs these files. But we want the index generation to happen
  in parallel. We cannot iterate over the files in the plugin directory as
  it is empty until the plugin has run. So unfortunately this logic lives in
  the v2 plugin.
  ]#
  b.withTree "do":
    b.addIdent v.plugin
    b.withTree "input":
      b.addStrLit v.files[0].nimFile
    b.withTree "output":
      b.addStrLit c.config.semmedFile(v.files[0], v.plugin)
    b.withTree "output":
      b.addStrLit c.config.indexFile(v.files[0], v.plugin)

proc generateFrontendBuildFile(c: DepContext; commandLineArgs: string; cmd: Command): string =
  result = c.config.nifcachePath / c.rootNode.files[0].modname & ".build.nif"
  var b = nifbuilder.open(result)
  defer: b.close()

  b.addHeader()
  b.withTree "stmts":
    # Command definitions
    defineNiflerCmd(b, c.nifler, preserveDocs = c.cmd == DoDoc)

    b.withTree "cmd":
      b.addSymbolDef "nimsem"
      b.addStrLit c.nimsem
      emitFrontendArgs(b, c.config.baseDir, commandLineArgs)
      b.addStrLit "m"
      b.addKeyw "args"
      # Module files are passed via (args) in each (do nimsem) block

    if cmd == DoCheck:
      b.withTree "cmd":
        b.addSymbolDef "idetools"
        b.addStrLit c.nimsem
        emitFrontendArgs(b, c.config.baseDir, commandLineArgs)
        b.addStrLit "idetools"
        b.addKeyw "args"
        b.withTree "input":
          b.addIntLit 0
          b.addIntLit -1 # all inputs

    if c.pluginSources.len > 0:
      # `nimsem <frontend args> plugin <source> <exe>`: builds a `{.plugin.}`
      # executable, validator included. One node per plugin, below.
      b.withTree "cmd":
        b.addSymbolDef "pluginbuild"
        b.addStrLit c.nimsem
        emitFrontendArgs(b, c.config.baseDir, commandLineArgs)
        b.addStrLit "plugin"
        b.addKeyw "input"
        b.addKeyw "output"

    for plugin in c.foundPlugins:
      b.withTree "cmd":
        b.addSymbolDef plugin
        b.addStrLit plugin
        b.addKeyw "args"
        b.withTree "input":
          b.addIntLit 0  # main parsed file
        b.withTree "output":
          b.addIntLit 0  # semmed file output
        # index file output is not explicitly passed to the plugin!
        #b.withTree "output":
        #  b.addIntLit 1  # index file output

    # Build rules for plugin executables. Every sem node that may run one
    # lists it as an input, which is what orders the build and makes it happen
    # exactly once, however many modules share the plugin.
    var pluginNames: seq[string] = @[]
    for name in c.pluginSources.keys: pluginNames.add name
    sort pluginNames, cmpNames
    for name in pluginNames:
      b.withTree "do":
        b.addIdent "pluginbuild"
        b.withTree "input":
          b.addStrLit c.pluginSources.getOrDefault(name)
        b.withTree "output":
          b.addStrLit c.pluginExe(name)

    # Build rules for semantic checking
    var i = 0
    for v in c.nodes:
      if v.plugin.len == 0:
        generateSemInstructions c, v, b, i == 0
      else:
        generatePluginSemInstructions c, v, b
      inc i

    # Build rules for parsing
    var seenFiles = initHashSet[string]()
    for v in c.nodes:
      if v.plugin.len > 0:
        continue
      for i in 0..<v.files.len:
        let f = c.config.parsedFile(v.files[i], c.cmd == DoDoc)
        if not seenFiles.containsOrIncl(f):
          let nimFile = v.files[i].nimFile
          if nimFile.endsWith(".nif"):
            continue
          b.withTree "do":
            b.addIdent "nifler"
            b.withTree "input":
              b.addStrLit nimFile
            b.withTree "output":
              b.addStrLit f

    if cmd == DoCheck and c.config.toTrack.mode != TrackNone:
      b.withTree "do":
        b.addIdent "idetools"
        for v in c.nodes:
          let s = c.config.semmedFile(v.files[0], v.plugin)
          b.withTree "input":
            b.addStrLit s

proc generateCachedConfigFile(c: DepContext; passC, passL: string): bool =
  ## Returns true when the configuration differs from the one the nimcache was
  ## last built with, i.e. when the sem results in it are for another set of
  ## options and have to be produced again.
  ##
  ## This is a MEMO nimony keeps for itself, NOT an `(input)` of the sem nodes.
  ## It used to be one, and that was the wrong model twice over: sem does not
  ## read this file, and an mtime cannot express "already built against this".
  ## Once the file was newer than outputs that a re-run had legitimately left
  ## untouched (nimsem writes OnlyIfChanged, so identical results keep their old
  ## mtime), every sem node stayed stale against it on every subsequent build —
  ## for good. Flipping a `-d:` flag and flipping it back was enough. The answer
  ## is not to fake a newer output; it is that "the options changed" means
  ## RE-RUN THIS STAGE, which is what the caller now says outright.
  let path = c.config.cachedConfigFile()
  # The ROOT MODULE is deliberately NOT part of this string. Every sem node
  # takes this file as an input (see `generateSemInstructions`), so anything in
  # here that differs between two builds sharing a nimcache invalidates all of
  # the other's sem results — and `executeExpr`'s const-eval sub-compile is
  # exactly such a second build: same nimcache, same options, but a generated
  # root (`nim<checksum>.p.nif`). With the root name in here the two overwrote
  # each other's entry on every run, so each build re-semmed everything the
  # other had just done, forever. The OPTIONS do belong here: two roots
  # compiled with different options really must invalidate each other, because
  # the `.s.nif` artifacts are keyed by module name and shared between them.
  let configStr = c.config.getOptionsAsOneString() &
                  " --passC:" & passC & " --passL:" & passL

  let needUpdate = if vfsExists(path) and not c.forceRebuild:
                     configStr != vfsRead(path)
                   else:
                     true
  if needUpdate:
    vfsWrite(path, configStr)
  result = needUpdate

proc initDepContext(config: sink NifConfig; project, nifler: string; isFinal, forceRebuild: bool; moduleFlags: set[ModuleFlag]; cmd: Command): DepContext =
  result = DepContext(nifler: nifler, config: config, rootNode: nil, includeStack: @[],
    forceRebuild: forceRebuild, moduleFlags: moduleFlags, nimsem: findTool("nimsem"),
    cmd: cmd, isGeneratingFinal: isFinal)
  let p = result.toPair(project)
  let root = Node(files: @[p], id: 0, parent: -1, active: 0, isSystem: IsSystem in moduleFlags)
  result.rootNode = root
  result.nodes.add root
  result.processedModules[p.modname] = 0
  traverseDeps result, p, root
  if not isFinal:
    propagatePlugins result

proc buildGraphForEval*(config: NifConfig; mainNifFile: string; dependencyNifFiles: seq[string];
    flags: set[BuildFlag]; moduleFlags: set[ModuleFlag]) =
  ## Build graph starting from already-processed .nif files instead of .nim files
  const requiredStdlibModules = [
    "std/writenif.nim", "std/syncio.nim", "std/math.nim", "std/formatfloat.nim"
  ]
  const requiredObjFiles = ["static.o"]

  # Generate a simplified build file that works with .nif files
  let buildFile = config.nifcachePath / splitModulePath(mainNifFile).name & ".exec.build.nif"
  var b = nifbuilder.open(buildFile)

  b.addHeader()
  b.withTree "stmts":
    # Command definitions (reuse existing logic)
    defineNiflerCmd(b, findTool("nifler"))

    b.withTree "cmd":
      b.addSymbolDef "nimsem"
      b.addStrLit findTool("nimsem")
      if config.baseDir.len > 0:
        b.addStrLit "--base:" & quoteShell(config.baseDir)
      # Match the OUTER frontend build file's `--cc:VAL` so nifmake's
      # per-cmd staleness check sees the same argv on both sides — without
      # this the static-eval helper's nifmake decides the existing
      # sysvq0asl.s.nif is stale and tries to rewrite it, and on Windows
      # the open fails because the outer (paused) nimsem still has the
      # file mmap'd via nifreader.
      if config.ccKey.len > 0:
        b.addStrLit "--cc:" & quoteShell(config.cc)
      b.addStrLit "m"
      b.addKeyw "args"
      b.withTree "input":
        b.addIntLit 0  # main parsed file

    b.withTree "cmd":
      b.addSymbolDef "lengc"
      b.addStrLit findTool("lengc")
      b.addStrLit "c"
      b.addStrLit "--compileOnly"
      b.addKeyw "args"
      b.addKeyw "input"

    defineHexerCmds(b, findTool("hexer"), config.bits, platform.CPU[config.targetCPU].endian == bigEndian,
                    config.targetOS, config.checkFlags, config.backend == backendNative)

    b.withTree "cmd":
      b.addSymbolDef "cc"
      b.addStrLit config.cc
      b.addStrLit "-c"
      b.addStrLit "-Wno-attributes"
      # See the sibling cc cmd above: real-GCC-only workaround for the gcc-14
      # arm64 stringop-overflow false positive.
      if extractCCKey(config.cc) != "clang" and
          config.targetOS notin {osMacosx, osIos}:
        b.addStrLit "-Wno-stringop-overflow"
      b.addKeyw "args"
      b.addKeyw "input"
      b.addStrLit "-o"
      b.addKeyw "output"

    b.withTree "cmd":
      b.addSymbolDef "link"
      b.addStrLit config.linker
      b.addStrLit "-o"
      b.addKeyw "output"
      b.withTree "input":
        b.addIntLit 0
        b.addIntLit -1  # all inputs
      b.withTree "argsext":
        b.addStrLit ".linker.args"
      # Clang on MinGW: native PE TLS code-gen + LLD lays out `.tls$` so the
      # loader sees it correctly; ld.bfd does not, leading to startup segfaults.
      if extractCCKey(config.linker) == "clang" and config.targetOS == osWindows:
        b.addStrLit "-fuse-ld=lld"

    # Collect all .nif files for DCE analysis
    var allNifFiles: seq[string] = @[]

    for module in requiredStdlibModules:
      let writenifNimFile = stdlibFile(module)
      let writenifSuffix = moduleSuffix(writenifNimFile, config.paths)
      allNifFiles.add(writenifSuffix)
      let writenifNifFile = config.nifcachePath / writenifSuffix & ".p.nif"
      let writenifSemmedFile = config.nifcachePath / writenifSuffix & ".s.nif"
      let writenifHexedFile = config.nifcachePath / writenifSuffix & ".x.nif"

      # Process writenif.nim with nifler to generate .nif file
      b.withTree "do":
        b.addIdent "nifler"
        b.withTree "input":
          b.addStrLit writenifNimFile
        b.withTree "output":
          b.addStrLit writenifNifFile

      # Process writenif .nif file with nimsem for semantic analysis
      b.withTree "do":
        b.addIdent "nimsem"
        b.withTree "input":
          b.addStrLit writenifNifFile
        b.withTree "output":
          b.addStrLit writenifSemmedFile

      b.withTree "do":
        b.addIdent "hexer"
        b.withTree "input":
          b.addStrLit writenifSemmedFile
        b.withTree "output":
          b.addStrLit writenifHexedFile


    var allRequiredStdlibModules = initHashSet[string]()
    for f in allNifFiles:
      allRequiredStdlibModules.incl f

    for depNifFile in dependencyNifFiles:
      let depName = depNifFile.splitModulePath.name
      if depName in allRequiredStdlibModules:
        continue
      allNifFiles.add(depName)
      let depHexedFile = config.nifcachePath / depName & ".s.nif"

      # Process dependency .nif file with hexer first
      b.withTree "do":
        b.addIdent "hexer"
        b.withTree "input":
          b.addStrLit depNifFile
        b.withTree "output":
          b.addStrLit depHexedFile

    # Build rules for main file
    let mainName = mainNifFile.splitModulePath.name
    allNifFiles.add(mainName)
    let mainHexedFile = config.nifcachePath / mainName & ".x.nif"

    # Process main .nif file with hexer first
    b.withTree "do":
      b.addIdent "hexer"
      b.withTree "args":
        b.addStrLit "--isMain"
      b.withTree "args":
        b.addStrLit "--app:" & $config.appType
      b.withTree "input":
        b.addStrLit mainNifFile
      b.withTree "output":
        b.addStrLit mainHexedFile

    b.withTree "do":
      b.addIdent "dce"
      for nifFile in allNifFiles:
        b.withTree "input":
          b.addStrLit config.nifcachePath / nifFile & ".x.nif"
        b.withTree "output":
          b.addStrLit config.nifcachePath / nifFile & ".c.nif"

    var objFiles: seq[string] = @[]
    for objFile in requiredObjFiles: objFiles.add(config.nifcachePath / objFile)
    for i, nifFile in pairs allNifFiles:
      b.withTree "do":
        b.addIdent "lengc"
        if i == 0:
          b.withTree "args":
            b.addStrLit "--isMain"
        b.withTree "input":
          b.addStrLit config.nifcachePath / nifFile & ".c.nif"
        b.withTree "output":
          b.addStrLit config.nifcachePath / nifFile & ".c"

      let objFile = config.nifcachePath / nifFile & ".o"
      b.withTree "do":
        b.addIdent "cc"
        b.withTree "input":
          b.addStrLit config.nifcachePath / nifFile & ".c"
        b.withTree "output":
          b.addStrLit objFile
      objFiles.add(objFile)

    # Link all object files to create executable
    let exeFile = config.nifcachePath / "main" & (when defined(windows): ".exe" else: "")
    b.withTree "do":
      b.addIdent "link"
      for objFile in objFiles:
        b.withTree "input":
          b.addStrLit objFile
      b.withTree "output":
        b.addStrLit exeFile
  b.close()

  # Execute the build using nifmake
  let nifmakeCmd = quoteShell(findTool("nifmake")) &
    (if ForceRebuild in flags: " --force" else: "") &
    " --base:" & quoteShell(config.baseDir) &
    " -j run " & quoteShell(buildFile)
  exec(nifmakeCmd)
  exec(exeFile)

# --- driving the build graph ----------------------------------------------
#
# One graph, run one of two ways (JIT_IMPL.md A2b):
#
# * a `nifmake` process, which is what every release before this one did and
#   what `--spawn:always` still does, down to the argv;
# * or `nifmake/dag.runDag` in *this* process, with `src/nimony/phases.nim`'s
#   scheduler deciding per node whether the node itself is worth a process.
#
# `dag.relayInstalled()` is the whole switch: `nimony`'s `main` installs the
# scheduler unless the user asked for the escape hatch, and nothing else in
# the toolchain installs a relay. So a `nimsem` that reaches this code (the
# legacy `nimsem e` path) keeps spawning, and so does a nimony-built nimony
# that decided some phase could not be linked.

proc makeJobs(): int =
  ## The per-depth process cap. `nimony --jobs:N` puts it in the environment
  ## rather than in `c.commandLineArgs` for the reason A1b gives for `--vfs`:
  ## a forwarded flag lands in the `.build.nif`, and two settings would then
  ## produce different build files. 0 means "all cores", nifmake's default and
  ## the bare `-j` every release before this one passed.
  ##
  ## A nimony-built compiler has no environment API, so it always answers "all
  ## cores" -- the same gap `inProcessMakeAvailable` documents, and the same
  ## consequence: a booted compiler behaves like the release before this one.
  when defined(nimony):
    0
  else:
    let v = getEnv("NIMONY_JOBS")
    if v.len == 0: return 0
    try:
      result = parseInt(v)
      if result < 1: result = 0
    except ValueError:
      result = 0

type
  MakeInvocation = object
    ## Everything both paths need, resolved once per build so the two cannot
    ## drift apart. Deliberately holds no type out of `dag.nim`: the object has
    ## to exist in a nimony-built compiler too, where that module is not
    ## imported at all.
    spawnPrefix: string        ## `nifmake … run ` (a trailing space)
    baseDir: string
    force, rerun: bool
    maxJobs: int
    inProcess: bool
    report: bool
    profile: bool
    silent: bool
    nested: bool               ## a build running INSIDE another compile

proc inProcessMakeAvailable(): bool =
  ## Is the in-process scheduler in front of the DAG? `nimony`'s `main`
  ## installs it unless the user asked for `--spawn:always`, and nothing else
  ## in the toolchain installs a relay -- so a `nimsem` that reaches this code
  ## (the legacy `nimsem e` path) keeps spawning and links none of the tools.
  when defined(nimony):
    false
  else:
    dag.relayInstalled()

proc initMakeInvocation(nifmake, baseDir: string; flags: set[BuildFlag];
                        rerun: bool; maxJobs: int; nested = false): MakeInvocation =
  result = MakeInvocation(
    spawnPrefix: quoteShell(nifmake) &
      (if ForceRebuild in flags: " --force" else: "") &
      (if Profile in flags: " --profile" else: "") &
      (if Report in flags: " --report" else: "") &
      " --base:" & quoteShell(baseDir) &
      (if rerun: " --rerun" else: "") &
      (if maxJobs == 1: "" elif maxJobs > 0: " -j:" & $maxJobs else: " -j") & " run ",
    baseDir: baseDir,
    force: ForceRebuild in flags,
    rerun: rerun,
    maxJobs: maxJobs,
    inProcess: inProcessMakeAvailable(),
    report: Report in flags,
    profile: Profile in flags,
    silent: SilentMake in flags or Report in flags,
    nested: nested)

proc runMake(inv: MakeInvocation; buildFile: string; lo, hi: int): bool {.discardable.} =
  ## Run one build graph. Failure ends the compile with the same message the
  ## spawned form produced, so a caller cannot tell the two apart from the
  ## outside except by the process tree.
  ##
  ## A NESTED build (A2c: the sub-program of a compile-time evaluation, run
  ## inside the very compiler that needs its result) is the one caller that
  ## must not be ended by a failed graph: the spawned form of that build was a
  ## child process whose non-zero exit code became the `const` site's error
  ## message, and a `quit` here would turn a bad `const` into a dead compiler.
  ## It gets `false` instead; every other caller keeps the `quit`.
  result = true
  if not inv.inProcess:
    let progress =
      if inv.silent: ""
      else: "--progress:" & $lo & ":" & $hi & " "
    exec inv.spawnPrefix & progress & quoteShell(buildFile)
    return true

  when not defined(nimony):
    # `--jobs:1` is sequential, not "one process at a time through
    # `execProcesses`": the whole point of asking for it is a build whose
    # output interleaving and node order are the DAG's, so it takes the path
    # that has no batch in it.
    var opt: set[dag.CliOption] = if inv.maxJobs == 1: {} else: {dag.Parallel}
    if inv.force: opt.incl dag.Force
    if inv.rerun: opt.incl dag.Rerun
    if inv.profile: opt.incl dag.Profile
    if inv.report: opt.incl dag.Report
    if not inv.silent: opt.incl dag.Progress
    var profile = dag.initProfileData()
    let parseStart = getMonoTime()
    var d = dag.parseNifFile(buildFile, inv.baseDir)
    profile.parseTime = dag.toSeconds(getMonoTime() - parseStart)
    let wantProfile = inv.profile or inv.report
    let ok = dag.runDag(d, opt, (if wantProfile: addr profile else: nil), lo, hi, inv.maxJobs)
    if inv.profile: stderr.write dag.profileText(profile)
    if inv.report:
      stdout.write dag.reportLine(profile)
      # A spawned nifmake flushed at process exit, i.e. before nimony went on
      # to link or to run the program. In-process the line would sit in this
      # process's buffer until `main` returns and surface AFTER the built
      # program's own output, which reads as a different build order than it
      # is.
      stdout.flushFile()
    if not ok:
      # The spawned form died inside `exec`, which prints the nifmake command
      # line it could not complete. In-process there is no command line for
      # the graph, and `runDag` has already named the node that failed, so the
      # build file is the useful identifier.
      #
      # Flush first. A failing node's diagnostics went to THIS process's
      # stdout, which is block-buffered when the compiler's output is a pipe,
      # while `quit` writes its message straight to stderr -- so without this
      # the trailer arrives before the error it is a trailer for. The spawned
      # form got the ordering for free because the child exited (and flushed)
      # before `exec` returned, and `hastur`'s `removeMakeErrors` strips
      # exactly the last `nifmake:`/`FAILURE:` lines, so the ordering is what
      # every `.msgs` golden of a failing compile depends on.
      stdout.flushFile()
      if inv.nested: return false
      quit "FAILURE: build graph " & buildFile

proc buildGraphImpl(config: sink NifConfig; project: string;
    flags: set[BuildFlag];
    commandLineArgs, commandLineArgsLengc: string; moduleFlags: set[ModuleFlag]; cmd: Command;
    passC, passL: string, executableArgs: string; nested: bool): bool =
  result = true
  let nifler = findTool("nifler")
  let nifmake = findTool("nifmake")
  let forceRebuild = ForceRebuild in flags

  if config.compat:
    let cfgNif = config.nifcachePath / moduleSuffix(project, []) & ".cfg.nif"
    exec quoteShell(nifler) & " config " & quoteShell(project) & " " &
      quoteShell(cfgNif)
    parseNifConfig cfgNif, config

  var c = initDepContext(config, project, nifler, false, forceRebuild, moduleFlags, cmd)
  let configChanged = generateCachedConfigFile(c, passC, passL)
  let buildFilename = generateFrontendBuildFile(c, commandLineArgs, cmd)
  #echo "run with: nifmake run ", buildFilename
  when defined(windows) and not defined(nimony):
    putEnv("CC", "gcc")
    putEnv("CXX", "g++")
  let nifmakeCommand = initMakeInvocation(nifmake, config.baseDir, flags,
                                          rerun = false, maxJobs = makeJobs(),
                                          nested = nested)
  # A changed configuration invalidates every sem result, and now says so
  # directly instead of through a file the sem nodes pretended to read.
  # `--rerun`, not `--force`: the outputs must stay in place so nimsem's
  # OnlyIfChanged writes can still find a result unchanged and spare the
  # entire backend.
  let frontendCommand = initMakeInvocation(nifmake, config.baseDir, flags,
                                           rerun = configChanged, maxJobs = makeJobs(),
                                           nested = nested)

  # `nimony c` drives nifmake once for the frontend and once more for the
  # backend (or docs); `DoCheck` stops after the frontend. Hand each invocation
  # a slice of the 0..100% range so nifmake's live bar reads as one continuous
  # indicator across the separate processes instead of restarting per phase.
  let twoPhase = cmd != DoCheck

  if not runMake(frontendCommand, buildFilename, 0, if twoPhase: 50 else: 100):
    return false

  if cmd == DoDoc:
    c = initDepContext(config, project, nifler, true, forceRebuild, moduleFlags, cmd)
    let docCacheDir = c.config.nifcachePath / "docs"
    let docOut = docOutDir(c.config)
    let projectRoot = toUnixPath(absoluteParentDir(c.rootNode.files[0].nimFile))
    let stdlibRoot = toUnixPath(stdlibDir())
    onRaiseQuit createDir(path(docCacheDir))
    onRaiseQuit createDir(path(docOut))
    # Pre-create the per-module subdirectories under outdir. dagon writes to
    # `<outdir>/<relpath>` and won't auto-mkdir intermediate components.
    for v in c.nodes:
      if v.plugin.len > 0: continue
      let relp = deriveRelpath(v.files[0].nimFile, projectRoot, stdlibRoot)
      let parent = docOut / parentDir(relp)
      if parent.len > 0 and parent != docOut:
        onRaiseQuit createDir(path(parent))
    let buildDocFilename = generateDocBuildFile(c)
    return runMake(nifmakeCommand, buildDocFilename, 50, 100)

  if cmd != DoCheck:
    # Parse `.s.deps.nif`.
    # It is generated by nimsem and doesn't contains modules imported under `when false:`.
    # https://github.com/nim-lang/nimony/issues/985
    c = initDepContext(config, project, nifler, true, forceRebuild, moduleFlags, cmd)
    let backend = c.config.nifcachePath / c.config.backendDirName(c.rootNode.files[0])
    onRaiseQuit createDir(path(backend))
    onRaiseQuit createDir(path(sharedObjDir()))
    # A compile-time-eval sub-program (`nimony s <sfx>.p.nif`, spawned by
    # `semos.runProgram`) shares the outer nimcache with every other
    # sub-program of the same compile, and 7 of its 8 modules are the stdlib
    # closure of `std/writenif` -- byte-identical from one sub-program to the
    # next, yet recompiled every time because each gets its own backend
    # directory. Run the backend in two graphs for those: analysis first, then
    # codegen with every non-main object resolved against the content-addressed
    # `<nimcache>/ocache/`. Restricted to the plain C backend without the
    # optimizer or custom `{.build.}`/`{.bundle.}` tools; anything else keeps
    # the single graph and emits exactly the build file it emits today.
    let useObjectCache = project.endsWith(".p.nif") and
                         c.config.backend == backendC and
                         c.config.optLevel notin {optSpeed, optSize} and
                         c.backendTools.len == 0 and c.bundles.len == 0
    if useObjectCache:
      let backendName = c.config.backendDirName(c.rootNode.files[0])
      # A2c: hexer + `dce` + `dceLive` first, so `<main>.live.nif` exists and
      # every non-main module's `.c.nif` can be looked up in the shared
      # `<nimcache>/ccache/` before its `dceEmit` node is offered to nifmake.
      let liveFile = generateFinalBuildFile(c, commandLineArgsLengc, passC, passL,
                                            fpLive)
      if not runMake(nifmakeCommand, liveFile, 50, 55):
        return false
      fillCNifCache(c, backendName)
      let analysisFile = generateFinalBuildFile(c, commandLineArgsLengc, passC, passL,
                                                fpAnalysis)
      if not runMake(nifmakeCommand, analysisFile, 55, 60):
        return false
      publishCNifCache(c, backendName)
      fillObjectCache(c, backendName, commandLineArgsLengc, passC)
      if c.config.ctfeAnalysisOnly:
        # `--ctfe-analysis-only`: the compiler that spawned this one runs these
        # `.c.nif` files itself (`semos.runEval` -> `engine.nim`), so the
        # codegen graph below -- lengc, the C compiler, the linker -- has
        # nothing to produce that anyone will read. Stopping here IS the
        # phase's win; everything above this line ran exactly as it does for a
        # subprocess evaluation, which is what keeps the two modes comparable.
        # The `Stats` block and the `DoRun` exec below are skipped with it:
        # nothing was built to report on, and a `.p.nif` sub-compile is never
        # `DoRun`.
        return true
    var thisPhase = fpWhole
    if useObjectCache: thisPhase = fpCodegen
    let buildFinalFilename = generateFinalBuildFile(c, commandLineArgsLengc, passC, passL,
                                                    thisPhase)
    # second (backend) phase: 50..100%
    # Linkers (gcc/clang/ld/ar) don't auto-create the output directory.
    # When the user passes `--out:bin/foo` or `--outdir:bin`, materialise
    # `bin/` here. Nim does the same in `prepareToWriteOutput`.
    var exeOutPath = c.config.exeFile(c.rootNode.files[0], c.config.backendDirName(c.rootNode.files[0]))
    if c.config.backend == backendWasm:
      exeOutPath = c.config.wasmFile(c.rootNode.files[0], c.config.backendDirName(c.rootNode.files[0]))
    let exeOutDir = exeOutPath.parentDir
    if exeOutDir.len > 0:
      onRaiseQuit createDir(path(exeOutDir))
    if not runMake(nifmakeCommand, buildFinalFilename, 50, 100):
      return false
    if useObjectCache:
      publishObjectCache(c, c.config.backendDirName(c.rootNode.files[0]))

  if Stats in flags:
    # Walk every source module in the dep graph and sum line counts. Counting
    # `\n` bytes in each `.nim` is cheap (sub-millisecond per file at this
    # scale); no caching needed since this only fires under `--stats`.
    var totalLines = 0
    var totalBytes = 0
    var nimFiles = 0
    var seen = initHashSet[string]()
    for v in c.nodes:
      if v.plugin.len > 0: continue
      for f in v.files:
        if not f.nimFile.endsWith(".nim"): continue
        if seen.containsOrIncl(f.nimFile): continue
        if not semos.fileExists(f.nimFile): continue
        try:
          let s = readFile(f.nimFile)
          inc nimFiles
          totalBytes += s.len
          # Count newlines; treat a file with no trailing newline as
          # contributing one extra line for its last content line.
          var n = 0
          for ch in s:
            if ch == '\n': inc n
          if s.len > 0 and s[^1] != '\n': inc n
          totalLines += n
        except:
          discard
    echo "[stats] ", nimFiles, " modules, ",
         totalLines, " LOC, ", totalBytes, " bytes"
    # The cost ledger's per-phase table (JIT.md 5.2 "Report"): what each phase
    # of this build cost, folded from the fragments the tools wrote. Printing
    # it also publishes `<nimcache>/ledger.nif`, the snapshot nifmake reads.
    var costs = openLedger(c.config.nifcachePath / "ledger.nif")
    let table = statsTable(costs)
    if table.len > 0:
      echo table
      saveLedger costs
    # And the artifact store beside it (JIT_IMPL.md A1d step 3). This is the
    # driver's own store: the tools' stores lived and died inside their own
    # processes, which is what `NIMONY_VFS_STATS=1` reports. Under the default
    # `--vfs:disk` the line says there is no store rather than printing zeros.
    echo storeStatsLine()

  if cmd != DoCheck:
    if cmd == DoRun:
      let backend = c.config.backendDirName(c.rootNode.files[0])
      if c.config.backend == backendWasm:
        # A .wasm module needs a host; run it under node with the standard
        # shim (tests/ithaqua/run_wasm.js provides env.nim_write/nim_exit).
        let shim = compilerDir() / "tests" / "ithaqua" / "run_wasm.js"
        exec "node " & quoteShell(shim) & " " &
             quoteShell(c.config.wasmFile(c.rootNode.files[0], backend)) & executableArgs
      else:
        exec c.config.exeFile(c.rootNode.files[0], backend) & executableArgs

proc buildGraph*(config: sink NifConfig; project: string;
    flags: set[BuildFlag];
    commandLineArgs, commandLineArgsLengc: string; moduleFlags: set[ModuleFlag]; cmd: Command;
    passC, passL: string, executableArgs: string) =
  ## The driver's entry point. A failed graph ends the compile inside
  ## `runMake`, so the `bool` is never anything but `true` here.
  discard buildGraphImpl(ensureMove config, project, flags, commandLineArgs,
                         commandLineArgsLengc, moduleFlags, cmd, passC, passL,
                         executableArgs, nested = false)

# ── A2c: the compile-time-evaluation sub-build, without the process ─────────
#
# `semos.runEval` used to compile a `const`'s sub-program by spawning
# `nimony <forwarded args> --ctfe-analysis-only --nimcache:<nc> s <sfx>.p.nif`.
# Since A2b that child ran every node of both its graphs in its own process
# already (`inproc=5`, `inproc=10`), so what the spawn still bought was nothing
# but a fresh set of frontend globals -- at the price of a process, its dyld
# work and a second `deps` scan of a module closure the caller already knows.
#
# The two halves of doing it here instead:
#
# 1. **The child's state, rebuilt.** Everything the spawned form derived from
#    its command line has to come out the same, because both forms write the
#    same `<sfx>.build.nif` into the same nimcache and nifmake decides
#    staleness from those bytes. `childArgs` below mirrors `nimony.nim`'s
#    `handleCmdLine` + `compileProgram` for exactly the options that can reach
#    a sub-compile: every nimony-specific option sets `forwardArg = false`, so
#    `commandLineArgs` can only carry `--path`, `-d:release`/`-d:danger` and
#    whatever `cli.parseCommonOption` forwards.
# 2. **The caller's state, preserved.** That is `semos`' job, not this
#    module's: see `takeFrontendState` there.

proc splitForwardedArg(tok: string; key, val: var string) =
  ## `--define:x` -> ("define", "x"). The forwarded args are built by
  ## `nimony.nim`/`nimsem.nim` as `" --" & key & ":" & val` with a RAW value,
  ## so there is no quoting to undo and no spaces to worry about -- the same
  ## assumption `semos.subprocessCtfeArgs` already makes when it splits this
  ## string on blanks.
  key.setLen 0
  val.setLen 0
  var i = 0
  while i < tok.len and tok[i] == '-': inc i
  while i < tok.len and tok[i] != ':' and tok[i] != '=':
    key.add tok[i]
    inc i
  if i < tok.len:
    val = tok.substr(i+1)

type
  ChildArgs = object
    ## What a spawned `nimony <commandLineArgs> s <project>` would hold after
    ## its own option loop. Named fields rather than four `var` parameters so
    ## the mirror of `handleCmdLine` reads as one thing.
    config: NifConfig
    moduleFlags: set[ModuleFlag]
    forwarded: string      ## `commandLineArgs` as the child would rebuild it
    forwardedLengc: string ## `commandLineArgsLengc`, derived the same way

proc childArgs(baseDir, nimcachePath, commandLineArgs, extraPath, outFile: string;
               analysisOnly: bool): ChildArgs =
  result = ChildArgs(config: initNifConfig(baseDir), moduleFlags: {},
                     forwarded: commandLineArgs, forwardedLengc: "")
  var danger = false
  var key = ""
  var val = ""
  for tok in commandLineArgs.split(' '):
    if tok.len == 0 or tok[0] != '-': continue
    splitForwardedArg(tok, key, val)
    if key.len == 0: continue
    var forwardArg = true
    var forwardArgLengc = false
    let keyNorm = normalize(key)
    if keyNorm == "path" or keyNorm == "p":
      result.config.paths.add val
    elif (keyNorm == "define" or keyNorm == "d") and
         (normalize(val) == "release" or normalize(val) == "danger"):
      # `nimony.nim` handles these two before the common parser: they define
      # the symbol AND imply the optimization level, and `danger` also turns
      # every runtime check off, which is what `--flags` below carries.
      result.config.addDefine val
      result.config.optLevel = optSpeed
      if normalize(val) == "danger": danger = true
    elif parseCommonOption(key, val, result.config, result.moduleFlags,
                           forwardArg, forwardArgLengc):
      discard "handled by the common CLI parser"
    if forwardArgLengc:
      result.forwardedLengc.add " --" & key
      if val.len > 0:
        result.forwardedLengc.add ":" & val

  if extraPath.len > 0:
    result.config.paths.add extraPath
    result.forwarded.add " --path:" & extraPath
  if outFile.len > 0:
    var fa = true
    var fl = false
    discard parseCommonOption("out", outFile, result.config, result.moduleFlags, fa, fl)
    result.forwarded.add " --out:" & outFile

  # `compileProgram`'s epilogue, in its order. The two `nimNative*` defines and
  # the `--flags` are appended to the forwarded string as well because the
  # child appends them to its own; `emitFrontendArgs` de-duplicates, so a
  # caller that already carried them and one that did not produce the same
  # `(cmd :nimsem …)`.
  if result.config.backend == backendLLVM:
    if result.config.linker.len == 0: result.config.linker = "clang"
  elif result.config.linker.len == 0 and result.config.cc.len > 0:
    result.config.linker = result.config.cc
  var checkModes: set[CheckMode] = DefaultSettings
  if danger: checkModes = {}
  if checkModes != DefaultSettings:
    let f = genFlags(checkModes)
    result.forwarded.add (if f.len > 0: " --flags:" & f else: " --flags")
  result.config.checkFlags = genFlags(checkModes)
  let nativeBackend = result.config.backend == backendNative
  let optOutAll = result.config.isDefined("useLibc")
  if nativeBackend or not (optOutAll or result.config.isDefined("useMimalloc")):
    result.config.addDefine "nimNativeAlloc"
    result.forwarded.add " --define:nimNativeAlloc"
  if nativeBackend or not (optOutAll or result.config.isDefined("useLibcIo")):
    result.config.addDefine "nimNativeIo"
    result.forwarded.add " --define:nimNativeIo"
  if nativeBackend:
    result.config.addDefine "nimNoLibc"
    result.forwarded.add " --define:nimNoLibc"

  setupPaths(result.config)
  # Last, so an explicit `--nimcache:` in the forwarded args cannot win over
  # the one the caller is actually using: the spawned form passed it after
  # everything else for the same reason.
  result.config.nifcachePath = nimcachePath
  result.config.ctfeAnalysisOnly = analysisOnly

proc runEvalBuild(nb: NestedBuild): int {.nimcall.} =
  ## `semos.evalBuildInProcess`. Answers the exit code the spawned
  ## `nimony … s <project>` would have answered: 0 on success, 1 on a graph
  ## that failed. `EvalBuildUnavailable` says the caller has to spawn -- there
  ## is no phase relay in this process (a bare `nimsem`, or a nimony-built
  ## nimony), so running the graph here would spawn a `nifmake` per graph and
  ## be strictly worse than the one process it replaced.
  if not inProcessMakeAvailable(): return EvalBuildUnavailable
  let a = childArgs(nb.baseDir, nb.nimcachePath, nb.commandLineArgs,
                    nb.extraPath, nb.outFile, nb.analysisOnly)
  # `SilentMake` and nothing else: `-f`, `--profile`, `--report` and `--stats`
  # are not forwarded to a sub-compile, so the spawned child had an empty set
  # too; the progress bar is dropped because a nested build is not a phase of
  # the outer one's 0..100 %.
  let ok = buildGraphImpl(a.config, nb.project, {SilentMake},
                          a.forwarded, a.forwardedLengc, a.moduleFlags,
                          DoCompile, "", "", "", nested = true)
  result = if ok: 0 else: 1

# Installed at module init rather than by a driver's `main`, because there are
# two drivers (`nimony`, `nimsem`) and both import this module while neither
# could import `phases`: `phases.nim` imports `nimsem`, so a `nimsem` that
# imported it back would be a module cycle. `semos` cannot import `deps` either
# (`deps` imports `semos`), which is what makes this a variable rather than a
# call.
semos.evalBuildInProcess = runEvalBuild
