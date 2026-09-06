#
#
#           Hexer Compiler
#        (c) Copyright 2025 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## Dead code elimination and generic instance merging.

import std / [os, tables, hashes, sets, assertions, syncio]
include ".." / lib / nifprelude
include ".." / lib / compat2

import ".." / lib / symparser
import ".." / lib / ledger
import dce1, hexerio
import ".." / lengc / [leng_model]

type
  ResolveTable* = Table[string, SymId]
    # `foo.1.I<type hash>` -> `foo.1.I<type hash>.module`
    # that is selected for the generic instance

proc prefersOffer(offerName, existingName, mainModule: string): bool =
  ## Ownership rule for an instantiation offered by several modules.
  ##
  ## The base rule is "the lexicographically smallest full name wins": every
  ## candidate shares the `key & '.'` prefix, so this compares module suffixes
  ## and is deterministic for a given set of modules.
  ##
  ## On top of that the MAIN module never owns a symbol another module also
  ## offers. The main module is the one participant that is guaranteed to
  ## differ between two programs built from the same libraries -- most sharply
  ## for the compile-time-eval sub-programs, whose main suffix is a checksum of
  ## the evaluated expression. Letting it win would make a *shared* module's
  ## `.c.nif` (an `imp` declaration naming the winner) depend on which main it
  ## happens to be linked with, and that in turn defeats the content-addressed
  ## object cache in `deps.buildGraph`. A symbol only the main module offers
  ## still stays there: this rule only ever demotes main in favour of an
  ## existing alternative.
  ##
  ## `mainModule` may be "" (unknown), in which case the base rule applies
  ## unchanged.
  if mainModule.len > 0:
    let offerIsMain = extractModule(offerName) == mainModule
    let existingIsMain = extractModule(existingName) == mainModule
    if offerIsMain != existingIsMain:
      return existingIsMain
  result = offerName < existingName

proc resolveSymbolConflicts(modules: Table[string, ModuleAnalysis];
                            mainModule: string): ResolveTable =
  # Resolve conflicts between duplicate symbols (e.g., generic instantiations)
  # Returns: symbol mapping from key to canonical
  result = initTable[string, SymId]()
  for m in modules.values:
    for offer in m.offers:
      let offerName = pool.syms[offer]
      let key = removeModule(offerName)
      let existing = result.getOrDefault(key, SymId(0))
      if existing == SymId(0) or prefersOffer(offerName, pool.syms[existing], mainModule):
        result[key] = offer

proc translate(resolved: ResolveTable; sym: SymId): SymId =
  let symName = pool.syms[sym]
  if isInstantiation(symName):
    let key = removeModule(symName)
    result = resolved.getOrDefault(key, sym)
  else:
    result = sym

proc markLive(moduleGraphs: Table[string, ModuleAnalysis]; resolved: ResolveTable): Table[string, HashSet[SymId]] =
  var worklist = newSeq[SymId](0)

  result = initTable[string, HashSet[SymId]]()

  for k, m in moduleGraphs:
    result[k] = initHashSet[SymId]()
    for root in m.roots:
      worklist.add(root)

  while worklist.len > 0:
    let sym = translate(resolved, worklist.pop())
    let moduleName = extractModule(pool.syms[sym])
    assert moduleName.len > 0, "moduleName is empty for " & pool.syms[sym]

    # Check if symbol is already live in its owning module
    if not result.getOrQuit(moduleName).containsOrIncl(sym):
      # Process dependencies from the symbol's own module
      if moduleName in moduleGraphs:
        let graph = moduleGraphs.getOrQuit(moduleName)
        if sym in graph.uses:
          for dep in graph.uses.getOrQuit(sym):
            let s = translate(resolved, dep)
            let sowner = extractModule(pool.syms[s])
            # Check if dependency is already live in its owning module
            if sowner.len > 0:
              assert sowner in result, "sowner is not in result for " & pool.syms[s]
            if sowner.len > 0 and s notin result.getOrQuit(sowner):
              worklist.add(s)

template toLengName(sym: SymId): SymId = sym

proc tr(dest: var TokenBuf; n: var Cursor; alive: HashSet[SymId]; resolved: ResolveTable) =
  case n.kind
  of TagLit:
    let stmtKind = n.stmtKind
    case stmtKind
    of TypeS:
      # types are fundamentally different from procs when it comes to generic instantiations:
      # We need to ensure **consistency** for types, but for procs we need to ensure **uniqueness**.
      let headTag = n.cursorTagId
      dest.addParLe(headTag, n.info)
      n.into:
        if n.isSymbolDef:
          let def = n.symId
          let t = translate(resolved, def)
          dest.addSymDef t.toLengName, n.info
          skip n # skip symbol def (atom)
          while n.hasMore:
            tr dest, n, alive, resolved
        else:
          # let errors propagate:
          while n.hasMore:
            tr dest, n, alive, resolved
      dest.addParRi()

    of ProcS, VarS, ConstS, GvarS, TvarS:
      let headTag = n.cursorTagId
      let headInfo = n.info
      n.into:
        if n.isSymbolDef:
          let def = n.symId
          if isLocalName(pool.syms[def]):
            dest.addParLe(headTag, headInfo)
            dest.addSymDef def.toLengName, n.info
            inc n # skip symbol def
            while n.hasMore:
              tr dest, n, alive, resolved
            dest.addParRi()
          elif alive.contains(def):
            let t = translate(resolved, def)
            if t != def:
              # we are a loser and need to add an `extern` declaration:
              dest.addParLe(globalTags.registerTag("imp"), headInfo)

              dest.addParLe(headTag, headInfo)
              dest.addSymDef t.toLengName, n.info
              inc n # skip symbol def
              var untilBody = if stmtKind == ProcS: 3 else: 2 # pragmas type (for procs: return type)
              while n.hasMore and untilBody > 0:
                dec untilBody
                tr dest, n, alive, resolved
              skip n # skip the body
              # replace it with an empty body:
              dest.addDotToken()
              dest.addParRi()
              dest.addParRi() # also close the "imp" declaration
            else:
              dest.addParLe(headTag, headInfo)
              dest.addSymDef def.toLengName, n.info
              inc n # skip symbol def
              while n.hasMore:
                tr dest, n, alive, resolved
              dest.addParRi()
          else:
            # skip it, it's dead
            inc n # skip symbol def
            while n.hasMore: skip n
        else:
          # let errors propagate:
          dest.addParLe(headTag, headInfo)
          while n.hasMore:
            tr dest, n, alive, resolved
          dest.addParRi()
    else:
      dest.addParLe(n.cursorTagId, n.info)
      n.into:
        while n.hasMore:
          tr dest, n, alive, resolved
      dest.addParRi()
  of Symbol:
    let t = translate(resolved, n.symId)
    dest.addSymUse t.toLengName, n.info
    inc n
  of SymbolDef:
    let t = translate(resolved, n.symId)
    dest.addSymDef t.toLengName, n.info
    inc n
  else: # atoms and suffix kinds; classic: a physical ParRi cannot appear here
    dest.takeTree n

proc rewriteBuf*(xbuf: var TokenBuf; live: HashSet[SymId];
                 resolved: ResolveTable): TokenBuf =
  ## The buffer-level `.x.nif` -> `.c.nif` rewrite: drop what is dead and
  ## point every generic instantiation at its elected owner. No file is read
  ## and none is written, which is what lets A2b run `dceEmit` in-process.
  var n = beginRead(xbuf)
  result = createTokenBuf(xbuf.len)
  tr result, n, live, resolved

proc emitOutPath*(xnif, outdir: string): string =
  ## Where `dceEmit` puts a module's `.c.nif`. Derived from the input's
  ## module name, exactly as `hexer c` derives its own outputs.
  if outdir.len > 0:
    outdir / splitModulePath(xnif).name & ".c.nif"
  else:
    xnif.changeModuleExt ".c.nif"

proc rewriteModule(file: string; live: HashSet[SymId]; resolved: ResolveTable;
                   outdir: string; t: var PhaseTimer; s: var HexerStatus) =
  ## Path-based wrapper: read -> `rewriteBuf` -> serialize -> write, with each
  ## step charged to its own ledger bucket.
  var buf = loadAndParse(file, t)
  var dest = rewriteBuf(buf, live, resolved)
  t.noteProduce()
  let outPath = emitOutPath(file, outdir)
  let content = serializeModule(dest, outPath)
  t.noteSerialize()
  writeSerialized(content, outPath, OnlyIfChanged, s)
  t.noteWrite()

proc deadCodeElimination*(files: openArray[string]; outdir: string;
                          s: var HexerStatus) =
  ## Single-shot DCE: read all .dce.nif analyses, compute global liveness,
  ## then sequentially rewrite each module's .x.nif to .c.nif. Kept for
  ## the single-process API; the build pipeline now goes through the split
  ## `computeLiveSet` + `dceEmit` pair so the per-module rewrite step
  ## parallelizes across modules.
  var graphs = initTable[string, ModuleAnalysis]()
  for file in files:
    let modName = splitModulePath(file).name
    graphs[modName] = readModuleAnalysis(file.changeModuleExt ".dce.nif")

  # No main-module marker in this API: `files` is a flat list whose order is
  # the caller's, so pass "" and keep the plain lexicographic ownership rule.
  let resolved = resolveSymbolConflicts(graphs, "")

  let live = markLive(graphs, resolved)
  var t = initPhaseTimer("", "", "")
  for file in files:
    if s.failed: return
    let modName = splitModulePath(file).name
    rewriteModule(file, live.getOrQuit(modName), resolved, outdir, t, s)

# ---- Split DCE: liveness computation and per-module emit -----------------

const
  liveTag    = "live"      # `(live (sym Symbol Symbol …))` — per-module live syms
  resolveTag = "resolved"  # `(resolved (kv String Symbol)*)` — generic-instance picks
  modTag     = "mod"       # `(mod String (sym …)*)` — block per module
  symTag     = "sym"

type
  LiveSet* = object
    ## The whole result of the liveness phase, and the object A2c caches
    ## across sub-programs: `resolved` (the elected owner of every generic
    ## instantiation) is a pure function of the participating modules' offer
    ## sets, so a second sub-program built from the same libraries can reuse
    ## it instead of re-electing. `writeLiveFile`/`readLiveFile` are only the
    ## file representation of this object.
    resolved*: ResolveTable
    live*: Table[string, HashSet[SymId]]

  DceInputs* = object
    ## The per-module `.dce.nif` analyses `computeLiveSet` folds, in the order
    ## the build graph emitted them. `names[0]` is the MAIN module:
    ## `deps.generateFinalBuildFile` emits the `dceLive` inputs in `c.nodes`
    ## order and `c.nodes[0]` is the root module, and `prefersOffer` needs to
    ## know which one that is.
    names*: seq[string]
    analyses*: seq[ModuleAnalysis]

proc addAnalysis*(inp: var DceInputs; name: string; a: sink ModuleAnalysis) =
  ## Append one module's analysis. The first one added is the main module.
  inp.names.add name
  inp.analyses.add a

proc writeLiveFile*(outfile: string; resolved: ResolveTable;
                    live: Table[string, HashSet[SymId]]) =
  ## Serialize the global DCE result to a single file consumed by all
  ## downstream `dceEmit` invocations. Symbols are written with their
  ## full module suffix (no abbreviation): the dotted-suffix shortcut
  ## expands using the reader's `thisModule` which is derived from the
  ## filename, but this file aggregates symbols from many modules — only
  ## one expansion would be correct, all the others would be wrong. So
  ## we pay the file-size cost rather than mis-expand.
  var b = nifbuilder.open(outfile, writeMode = OnlyIfChanged)
  b.withTree "stmts":
    b.withTree resolveTag:
      for key, winner in pairs(resolved):
        b.withTree "kv":
          b.addStrLit key
          b.addSymbol pool.syms[winner], ""
    b.withTree liveTag:
      for modName, syms in pairs(live):
        b.withTree modTag:
          b.addStrLit modName
          for s in syms:
            b.addSymbol pool.syms[s], ""
  b.close()

proc writeLiveFile*(outfile: string; ls: LiveSet) {.inline.} =
  ## Overload over the result object, so a caller that keeps a `LiveSet`
  ## around does not have to take it apart again.
  writeLiveFile(outfile, ls.resolved, ls.live)

proc parseLiveSet*(n0: Cursor; ctx: string): LiveSet =
  ## The buffer-level reader for a `.live.nif`. `ctx` only names the source in
  ## the diagnostics.
  var n = n0
  let infile = ctx
  result = LiveSet(
    resolved: initTable[string, SymId](),
    live: initTable[string, HashSet[SymId]]())
  if n.stmtKind != StmtsS:
    raiseAssert infile & ": expected (stmts ...)"
  let liveTagId = globalTags.registerTag(liveTag)
  let resolveTagId = globalTags.registerTag(resolveTag)
  let modTagId = globalTags.registerTag(modTag)
  n.into:                                       # (stmts ...)
    while n.hasMore:
      if not n.isTagLit:
        raiseAssert infile & ": expected ParLe"
      if n.cursorTagId == resolveTagId:
        n.into:                                 # (resolved ...)
          while n.hasMore:
            if n.isTagLit and n.substructureKind == KvU:
              n.into:                           # (kv ...)
                if not n.isStringLit:
                  raiseAssert infile & ": kv key must be StringLit"
                let key = pool.strings[n.strId]
                skip n
                if n.kind != Symbol:
                  raiseAssert infile & ": kv value must be Symbol"
                result.resolved[key] = n.symId
                skip n
                if n.hasMore:
                  raiseAssert infile & ": expected ')' closing kv"
            else:
              raiseAssert infile & ": expected (kv …)"
      elif n.cursorTagId == liveTagId:
        n.into:                                 # (live ...)
          while n.hasMore:
            if not n.isTagLit or n.cursorTagId != modTagId:
              raiseAssert infile & ": expected (mod …)"
            n.into:                             # (mod ...)
              if not n.isStringLit:
                raiseAssert infile & ": (mod) name must be StringLit"
              let modName = pool.strings[n.strId]
              skip n
              var syms = initHashSet[SymId]()
              while n.hasMore:
                if n.kind != Symbol:
                  raiseAssert infile & ": expected Symbol in (mod)"
                syms.incl n.symId
                skip n
              result.live[modName] = syms
      else:
        raiseAssert infile & ": expected (resolved|live …)"

proc readLiveFile*(infile: string): LiveSet =
  ## Path-based wrapper: read -> parse -> `parseLiveSet`.
  var buf = parseFromFile(infile)
  result = parseLiveSet(beginRead(buf), infile)

proc readLiveFile*(infile: string; t: var PhaseTimer): LiveSet =
  ## Same, with the read and the parse charged to their own ledger buckets.
  var buf = loadAndParse(infile, t)
  result = parseLiveSet(beginRead(buf), infile)

proc computeLiveSet*(inputs: DceInputs): LiveSet =
  ## The buffer-level liveness phase: elect an owner for every generic
  ## instantiation and mark what each module has to keep. No file is read and
  ## none is written.
  var graphs = initTable[string, ModuleAnalysis]()
  var mainModule = ""
  for i in 0 ..< inputs.names.len:
    if mainModule.len == 0: mainModule = inputs.names[i]
    graphs[inputs.names[i]] = inputs.analyses[i]
  let resolved = resolveSymbolConflicts(graphs, mainModule)
  result = LiveSet(resolved: resolved, live: markLive(graphs, resolved))

proc loadDceInputs*(dceFiles: openArray[string]; t: var PhaseTimer): DceInputs =
  ## Read the per-module `.dce.nif` analyses named on the command line,
  ## keeping the caller's order (entry 0 is the main module).
  result = DceInputs(names: @[], analyses: @[])
  for file in dceFiles:
    result.addAnalysis(splitModulePath(file).name, readModuleAnalysis(file, t))

proc computeLiveSet*(dceFiles: openArray[string]; liveOut: string;
                     t: var PhaseTimer) =
  ## Path-based wrapper: read the `.dce.nif` analyses, compute the global
  ## resolve table + live sets, and write them to `liveOut`. This is the
  ## small serial step in the split DCE pipeline.
  let inputs = loadDceInputs(dceFiles, t)
  let ls = computeLiveSet(inputs)
  t.noteProduce()
  writeLiveFile(liveOut, ls)
  t.noteWrite()

proc computeLiveSet*(dceFiles: openArray[string]; liveOut: string) =
  ## Untimed path-based wrapper (the pre-A2a signature).
  var t = initPhaseTimer("", "", "")
  computeLiveSet(dceFiles, liveOut, t)

proc liveOf*(ls: LiveSet; modName: string): HashSet[SymId] =
  ## What `modName` has to keep. A module the liveness phase never saw keeps
  ## nothing, which is what makes an unreferenced module compile to an empty
  ## `.c.nif` rather than a crash.
  if ls.live.hasKey(modName): ls.live.getOrQuit(modName)
  else: initHashSet[SymId]()

proc dceEmit*(xnif: string; ls: LiveSet; outdir: string;
              t: var PhaseTimer; s: var HexerStatus) =
  ## Per-module emit against a `LiveSet` the caller already holds. This is the
  ## overload A2b/A2c use: the `.live.nif` is read once and N modules are
  ## emitted from it.
  rewriteModule(xnif, liveOf(ls, splitModulePath(xnif).name), ls.resolved,
                outdir, t, s)

proc dceEmit*(xnif, liveFile, outdir: string; t: var PhaseTimer;
              s: var HexerStatus) =
  ## Per-module emit: read `M.x.nif` plus the shared `liveFile`, write
  ## `M.c.nif`. Multiple invocations run in parallel under the build
  ## scheduler.
  let ls = readLiveFile(liveFile, t)
  dceEmit(xnif, ls, outdir, t, s)

proc dceEmit*(xnif, liveFile, outdir: string; s: var HexerStatus) =
  ## Untimed path-based wrapper (the pre-A2a signature plus its status).
  var t = initPhaseTimer("", "", "")
  dceEmit(xnif, liveFile, outdir, t, s)
