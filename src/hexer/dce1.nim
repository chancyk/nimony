#
#
#           Hexer Compiler
#        (c) Copyright 2025 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## Prepare for dead code elimination and generic instance merging.

import std / [assertions, tables, hashes, sets, syncio, algorithm]
include ".." / lib / nifprelude
include ".." / lib / compat2
import ".." / lengc / [leng_model]

import ".." / lib / symparser
import ".." / lib / ledger
import hexerio

type
  ModuleAnalysis* = object
    uses*: Table[SymId, HashSet[SymId]]
    roots*: HashSet[SymId]
    offers*: HashSet[SymId] # generic instances that are offered by this module

proc tr(n: var Cursor; a: var ModuleAnalysis; owner: SymId) =
  case n.kind
  of TagLit:
    case n.stmtKind
    of ProcS, TypeS, VarS, ConstS, GvarS, TvarS:
      n.into:
        var newOwner = owner
        if n.isSymbolDef:
          let symName = pool.syms[n.symId]
          if isInstantiation(symName):
            a.offers.incl(n.symId)
          if not isLocalName(symName):
            newOwner = n.symId
        while n.hasMore:
          tr n, a, newOwner
    else:
      if n.substructureKind == PragmasU:
        # Check if this pragma section contains exportc or interrupt.
        # If so, mark the owner as a root: both name entry points nothing in the
        # program calls. An `{.interrupt.}` handler is reached ONLY through the
        # interrupt table, which the back end builds after this pass runs — so
        # without this it is unreachable by construction, gets deleted, and the
        # failure is a device that silently never responds to the interrupt.
        var isEntryPoint = false
        n.into:
          while n.hasMore:
            if n.isTagLit and n.pragmaKind in {ExportcP, InterruptP}:
              isEntryPoint = true
            tr n, a, owner
        if isEntryPoint and owner != SymId(0):
          a.roots.incl(owner)
      else:
        let isFld = n.substructureKind == FldU
        n.into:
          if isFld and n.kind == SymbolDef:
            let symName = pool.syms[n.symId]
            if isInstantiation(symName):
              a.offers.incl(n.symId)
          while n.hasMore:
            tr n, a, owner
  of Symbol:
    if not isLocalName(pool.syms[n.symId]):
      if owner == SymId(0):
        a.roots.incl(n.symId)
      else:
        if not a.uses.hasKey(owner): a.uses[owner] = initHashSet[SymId]()
        a.uses.getOrQuit(owner).incl(n.symId)
    inc n
  of SymbolDef, UnknownToken, EofToken, ParLe, ParRi, ExtendedSuffix, LineInfoLit, DotToken, Ident, StrLit, CharLit, IntLit, UIntLit, FloatLit: inc n
  else: raiseAssert "ParRi should not be encountered here" # classic ParRi only

const
  depName = "uses"
  offerName = "offers"
  rootName = "roots"

proc analyzeModule*(n: Cursor): ModuleAnalysis =
  ## The buffer-level half of the `.dce.nif` step (JIT_IMPL.md A2a): walk a
  ## module's Leng and answer with the roots/uses/offers graph. Nothing here
  ## touches a file, so `expand`'s in-process caller can keep the object and
  ## hand it straight to `computeLiveSet` instead of round-tripping it
  ## through `.dce.nif`.
  var n = n
  result = ModuleAnalysis()
  tr n, result, SymId(0)

proc cmpSymNames*(a, b: string): int =
  ## `sort` needs an explicit comparator under Nimony, whose stdlib has no
  ## generic `cmp`. Same idiom as `deps.cmpNames`.
  if a < b: -1 elif a > b: 1 else: 0

proc sortedSymNames*(syms: HashSet[SymId]): seq[string] =
  ## The symbol names of `syms`, in a deterministic order.
  ##
  ## A `HashSet[SymId]` iterates in hash order of the POOL INDEX, and a pool
  ## index depends on the order in which the whole process interned symbols.
  ## Adding one symbol to a module therefore reshuffles every set that
  ## mentions symbols interned after it, and the `.dce.nif` bytes change even
  ## though the analysis did not (JIT_IMPL.md P0c; `notes/p0c.md` section 1).
  ## Sorting by name makes the file a function of its content alone, which is
  ## what `OnlyIfChanged` needs in order to mean anything.
  result = newSeq[string](0)
  for s in syms: result.add pool.syms[s]
  sort result, cmpSymNames

proc writeAnalysis*(outputFilename: string; a: var ModuleAnalysis;
                    dottedSuffix: string) =
  ## Serialize one `ModuleAnalysis` as `.dce.nif`. Symbols are abbreviated
  ## against `dottedSuffix`; `readModuleAnalysis` expands them again from the
  ## file name, so the round trip is the identity.
  ##
  ## Everything is emitted in sorted-by-name order (see `sortedSymNames`), so two
  ## runs that computed the same analysis produce the same bytes and the
  ## `OnlyIfChanged` write preserves the mtime. `parseAnalysis` reads into
  ## sets and tables, so the order is not observable anywhere else.
  var b = nifbuilder.open(outputFilename, writeMode = OnlyIfChanged)
  b.withTree "stmts":
    b.withTree rootName:
      for root in sortedSymNames(a.roots):
        b.addSymbol root, dottedSuffix
    var owners = newSeq[string](0)
    var byName = initTable[string, SymId]()
    for owner in a.uses.keys:
      let n = pool.syms[owner]
      owners.add n
      byName[n] = owner
    sort owners, cmpSymNames
    for owner in owners:
      b.withTree depName:
        b.addSymbol owner, dottedSuffix
        for dep in sortedSymNames(a.uses.getOrQuit(byName.getOrQuit(owner))):
          b.addSymbol dep, dottedSuffix
    b.withTree offerName:
      for offer in sortedSymNames(a.offers):
        b.addSymbol offer, dottedSuffix
  b.close()

proc parseAnalysis*(n0: Cursor; ctx: string): ModuleAnalysis =
  ## The buffer-level reader for a `.dce.nif`. `ctx` only names the source in
  ## the diagnostics; nothing here opens a file, so an in-process caller can
  ## feed it a buffer it already holds.
  var n = n0
  result = ModuleAnalysis()
  let infile = ctx
  if n.stmtKind == StmtsS:
    let depTag = globalTags.registerTag(depName)
    let offerTag = globalTags.registerTag(offerName)
    let rootTag = globalTags.registerTag(rootName)
    n.into:                                     # (stmts ...)
      while n.hasMore:
        if not n.isTagLit:
          raiseAssert infile & ": expected ParLe"
        if n.cursorTagId == rootTag:
          n.into:                               # (roots ...)
            while n.hasMore:
              if n.kind == Symbol:
                result.roots.incl(n.symId)
                skip n
              else:
                raiseAssert infile & ": expected Symbol"
        elif n.cursorTagId == depTag:
          n.into:                               # (uses ...)
            let key = n.symId
            result.uses[key] = initHashSet[SymId]()
            skip n
            while n.hasMore:
              if n.kind == Symbol:
                result.uses.getOrQuit(key).incl(n.symId)
                skip n
              else:
                raiseAssert infile & ": expected Symbol"
        elif n.cursorTagId == offerTag:
          n.into:                               # (offers ...)
            while n.hasMore:
              if n.kind == Symbol:
                result.offers.incl(n.symId)
                skip n
              else:
                raiseAssert infile & ": expected Symbol"
        else:
          raiseAssert infile & ": expected (roots|uses|offers)"

proc readModuleAnalysis*(infile: string): ModuleAnalysis =
  ## Path-based wrapper: read -> parse -> analyse.
  var buf = parseFromFile(infile)
  result = parseAnalysis(beginRead(buf), infile)

proc readModuleAnalysis*(infile: string; t: var PhaseTimer): ModuleAnalysis =
  ## Same, with the read and the parse charged to their own ledger buckets.
  var buf = loadAndParse(infile, t)
  result = parseAnalysis(beginRead(buf), infile)

proc writeDceOutput*(buf: var TokenBuf; outfile, dottedSuffix: string) =
  ## Direct overload that works on an already-parsed token buffer,
  ## avoiding the file read + parse step.
  var a = analyzeModule(beginRead(buf))
  writeAnalysis(outfile, a, dottedSuffix)
