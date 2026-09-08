#
#
#           Hexer Compiler
#        (c) Copyright 2025 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## Dead code elimination and generic instance merging.

import std / [os, tables, hashes, sets, assertions, syncio, algorithm]
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
      let key = pool.symWithoutModule(offer)
      let existing = result.getOrDefault(key, SymId(0))
      # P0b's ownership rule, on upstream's accessors: the `offerName` binding
      # this used to read was dropped when the loop head moved to
      # `pool.symWithoutModule`, so the spelling is asked for directly.
      if existing == SymId(0) or
         prefersOffer(pool.symString(offer), pool.symString(existing), mainModule):
        result[key] = offer

proc translate(resolved: ResolveTable; sym: SymId): SymId =
  if pool.symIsInstantiation(sym):
    result = resolved.getOrDefault(pool.symWithoutModule(sym), sym)
  else:
    result = sym

proc markLive(moduleGraphs: var Table[string, ModuleAnalysis];
              resolved: ResolveTable): Table[string, HashSet[SymId]] =
  ## The reachability fixpoint: start from every module's roots and follow
  ## `uses` until nothing new becomes live.
  ##
  ## `moduleGraphs` is a `var` parameter and the two lookups below are written
  ## as chained `getOrQuit` calls ON PURPOSE, and neither is cosmetic.
  ## `getOrQuit` has a mutable and an immutable overload (`lib/compat2.nim`);
  ## the immutable one returns `B` BY VALUE. Binding
  ## `let graph = moduleGraphs.getOrQuit(moduleName)` therefore deep-copied a
  ## whole `ModuleAnalysis` -- a `Table[SymId, HashSet[SymId]]` plus two
  ## `HashSet`s, thousands of entries for a module like `sem` -- on EVERY
  ## worklist pop, and `graph.uses.getOrQuit(sym)` copied the dependency set
  ## on top of that. On the self-compilation that is 7867 pops over 131
  ## modules and it cost 313 ms of `dceLive`'s 356 ms; taking the mutable
  ## overload instead makes the same fixpoint 7 ms (`notes/h1.md` section 1).
  ## The result is bit-for-bit the same set -- the copies were pure waste.
  var worklist = newSeq[SymId](0)

  result = initTable[string, HashSet[SymId]]()

  for k, m in moduleGraphs:
    result[k] = initHashSet[SymId]()
    for root in m.roots:
      worklist.add(root)

  while worklist.len > 0:
    let sym = translate(resolved, worklist.pop())
    let moduleName = pool.symModule(sym)
    assert moduleName.len > 0, "moduleName is empty for " & pool.symString(sym)

    # Check if symbol is already live in its owning module
    if not result.getOrQuit(moduleName).containsOrIncl(sym):
      # Process dependencies from the symbol's own module
      if moduleName in moduleGraphs:
        if moduleGraphs.getOrQuit(moduleName).uses.hasKey(sym):
          for dep in moduleGraphs.getOrQuit(moduleName).uses.getOrQuit(sym):
            let s = translate(resolved, dep)
            let sowner = pool.symModule(s)
            # Check if dependency is already live in its owning module
            if sowner.len > 0:
              assert sowner in result, "sowner is not in result for " & pool.symString(s)
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
          if pool.symIsLocal(def):
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

proc addResolved(b: var Builder; resolved: ResolveTable; keys: openArray[string]) =
  ## `(resolved (kv key winner)*)` for `keys`, which the caller has sorted.
  b.withTree resolveTag:
    for key in keys:
      if resolved.hasKey(key):
        b.withTree "kv":
          b.addStrLit key
          b.addSymbol pool.symString(resolved.getOrQuit(key)), ""

proc addLiveMod(b: var Builder; modName: string; syms: HashSet[SymId]) =
  ## One `(mod "name" sym*)` block, symbols in sorted-by-name order.
  b.withTree modTag:
    b.addStrLit modName
    for s in sortedSymNames(syms):
      b.addSymbol s, ""

proc sortedResolveKeys(resolved: ResolveTable): seq[string] =
  result = newSeq[string](0)
  for key in resolved.keys: result.add key
  sort result, cmpSymNames

proc writeLiveFile*(outfile: string; resolved: ResolveTable;
                    live: Table[string, HashSet[SymId]];
                    mode = OnlyIfChanged) =
  ## Serialize the whole-program DCE result. Symbols are written with their
  ## full module suffix (no abbreviation): the dotted-suffix shortcut
  ## expands using the reader's `thisModule` which is derived from the
  ## filename, but this file aggregates symbols from many modules -- only
  ## one expansion would be correct, all the others would be wrong. So
  ## we pay the file-size cost rather than mis-expand.
  ##
  ## Everything is emitted sorted by NAME. A `Table`/`HashSet` keyed by
  ## `SymId` iterates in hash order of a pool index, and a pool index depends
  ## on the order in which this process happened to intern symbols -- so one
  ## extra symbol anywhere in the program reshuffled the entire file and the
  ## `OnlyIfChanged` write below never fired. That is what made a body-only
  ## edit re-run all 127 `dceEmit` nodes (JIT_IMPL.md P0c, `notes/p0c.md`).
  ##
  ## `mode` is `AlwaysWrite` when this file is the `dceLive` node's staleness
  ## anchor; see `writeModuleLiveFiles`.
  var b = nifbuilder.open(outfile, writeMode = mode)
  b.withTree "stmts":
    addResolved b, resolved, sortedResolveKeys(resolved)
    b.withTree liveTag:
      var mods = newSeq[string](0)
      for modName in live.keys: mods.add modName
      sort mods, cmpSymNames
      for modName in mods:
        addLiveMod b, modName, live.getOrQuit(modName)
  b.close()

proc writeLiveFile*(outfile: string; ls: LiveSet; mode = OnlyIfChanged) {.inline.} =
  ## Overload over the result object, so a caller that keeps a `LiveSet`
  ## around does not have to take it apart again.
  writeLiveFile(outfile, ls.resolved, ls.live, mode)

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

proc liveOf*(ls: LiveSet; modName: string): HashSet[SymId] =
  ## What `modName` has to keep. A module the liveness phase never saw keeps
  ## nothing, which is what makes an unreferenced module compile to an empty
  ## `.c.nif` rather than a crash.
  if ls.live.hasKey(modName): ls.live.getOrQuit(modName)
  else: initHashSet[SymId]()

proc addInstantiationKey(keys: var HashSet[string]; sym: SymId) {.inline.} =
  let name = pool.symString(sym)
  if isInstantiation(name): keys.incl removeModule(name)

proc resolveKeysOf(a: ModuleAnalysis; liveSyms: HashSet[SymId]): seq[string] =
  ## Every resolve-table key a module can ever look up, derived from its own
  ## analysis. `tr` above calls `translate` for (1) a `TypeS` symbol DEF,
  ## (2) a non-local, alive `ProcS`/`VarS`/`ConstS`/`GvarS`/`TvarS` symbol
  ## def, (3) every `Symbol` USE and (4) any other `SymbolDef`. `translate` is
  ## the identity unless the name `isInstantiation`, and an instantiation name
  ## always carries a module suffix, so a local name never reaches the table --
  ## which leaves (4) with nothing but its `fld` half. `dce1.analyzeModule`
  ## records (1), (2) and that `fld` half in `offers`, and the non-local half
  ## of (3) in `roots`/`uses`. The live set is folded in as well: those are the
  ## defs `tr` keeps and then translates.
  ##
  ## So this is a superset of what one module's emit can ask for, and a small
  ## fraction of the whole table -- which is the point: the whole table copied
  ## into every module's file would be 39 MB on the self-compilation.
  var keys = initHashSet[string]()
  for s in a.roots: addInstantiationKey keys, s
  for s in a.offers: addInstantiationKey keys, s
  for owner, uses in pairs(a.uses):
    addInstantiationKey keys, owner
    for dep in uses: addInstantiationKey keys, dep
  for s in liveSyms: addInstantiationKey keys, s
  result = newSeq[string](0)
  for k in keys: result.add k
  sort result, cmpSymNames

proc moduleLiveFile*(dir, modName: string): string {.inline.} =
  ## Where module `modName`'s own live file lives. The whole-program file that
  ## sits beside it is named `<main>.all.live.nif`, so the two never collide
  ## even though the main module has a per-module file of its own.
  dir / modName & ".live.nif"

proc writeModuleLiveFiles*(dir: string; inputs: DceInputs; ls: LiveSet) =
  ## Split the whole-program result into one `<M>.live.nif` per module, each
  ## holding exactly what that module's `dceEmit` reads: its own live set and
  ## the resolve entries it can consult (`resolveKeysOf`). The shape is the
  ## same as the whole-program file, so `parseLiveSet`, `readLiveFile`,
  ## `liveOf` and both `dceEmit` overloads need no change.
  ##
  ## Each file is written `OnlyIfChanged`, and that is the phase: a module
  ## whose live set did not move keeps its mtime, nifmake leaves its `dceEmit`
  ## node alone, and the `lengc`/`cc` below it stay put too. The whole-program
  ## file is the node's always-written staleness anchor, because a `dceLive`
  ## run whose outputs are ALL `OnlyIfChanged` and all unchanged would leave
  ## every output older than the input that woke it and re-fire forever
  ## (`dag.needsRebuild`'s "freshest output" comment).
  for i in 0 ..< inputs.names.len:
    let modName = inputs.names[i]
    let syms = liveOf(ls, modName)
    var b = nifbuilder.open(moduleLiveFile(dir, modName), writeMode = OnlyIfChanged)
    b.withTree "stmts":
      addResolved b, ls.resolved, resolveKeysOf(inputs.analyses[i], syms)
      b.withTree liveTag:
        addLiveMod b, modName, syms
    b.close()

proc computeLiveSet*(dceFiles: openArray[string]; liveOut: string;
                     t: var PhaseTimer; splitDir = "") =
  ## Path-based wrapper: read the `.dce.nif` analyses, compute the global
  ## resolve table + live sets, and write them to `liveOut`. This is the
  ## small serial step in the split DCE pipeline.
  ##
  ## With `splitDir` (the build graph's `--split:<dir>`) it also writes one
  ## `<M>.live.nif` per module into that directory, and `liveOut` becomes the
  ## node's always-written staleness anchor rather than an input of anything.
  ## Without it the behaviour is exactly the pre-P0c one, which is what a
  ## hand-run `hexer dl` and `tests/inproc/hexer` get.
  let inputs = loadDceInputs(dceFiles, t)
  let ls = computeLiveSet(inputs)
  t.noteProduce()
  if splitDir.len > 0:
    writeLiveFile(liveOut, ls, AlwaysWrite)
    writeModuleLiveFiles(splitDir, inputs, ls)
  else:
    writeLiveFile(liveOut, ls)
  t.noteWrite()

proc computeLiveSet*(dceFiles: openArray[string]; liveOut: string) =
  ## Untimed path-based wrapper (the pre-A2a signature).
  var t = initPhaseTimer("", "", "")
  computeLiveSet(dceFiles, liveOut, t)

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
