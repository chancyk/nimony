#
#
#        Lengc set-of-modules handling — nifcore port
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## NIF set-of-modules handling on the **nifcore** stack — the nifcore port of
## `lengc/nifmodules.nim`. Loads foreign declarations lazily, IC-style: a
## module's `.nif` file is opened once, its embedded index (`(.index (x sym
## offset) …)`) read, and each requested declaration materialized on demand by
## seeking the reader to the indexed offset and parsing exactly one subtree.
##
## Compared to the nifcursors original this is simpler: `nifcoreparse.parse`
## replaces the hand-rolled recursive token copier, and `nifstreams` drops out
## entirely — `nifreader.Reader` already provides `jumpTo`/`offset`, and the
## embedded index is read at the raw-token level with no pool involvement.

import std / [assertions, tables, syncio] # syncio: `quit`
import ".." / "lib" / nifcoreparse        # re-exports nifcore + parse
import ".." / "lib" / nifcdecl              # stmtKind/symKind/pragmaKind, decls
import ".." / "lib" / nifreader as rd       # Reader, jumpTo, indexStartsAt
import ".." / "lib" / symparser             # splitSymName, splitModulePath, basename
import ".." / "lib" / foreignmodules         # shared lazy loader (ForeignModule)
import ".." / "lib" / bif                    # binary NIF: isBifFile probe + load
import ".." / "lib" / vfs                     # relayed existence check
import noptions                              # ConfigRef

type
  Definition* = object
    pos*: Cursor            ## points into the owning ForeignModule's decl buffer
    kind*: LengSym
    extern*: StrId          ## importc/exportc name, cached (frequently queried)
    isImport*: bool         ## true for importc/importcpp, false for exportc-only
    bareImport*: bool       ## `importc` with neither `header` nor `nodecl`: the
                            ## C backend declares it itself, under its MANGLED
                            ## name with an `__asm__` label, so the declaration
                            ## can never collide with a header prototype for the
                            ## same libc identifier in the same TU (splices move
                            ## such references into arbitrary modules)

  NifProgram = object
    mods: Table[string, ForeignModule]   ## module suffix -> lazily-opened module
    scheme: SplittedModulePath

  TypeScope* {.acyclic.} = ref object
    locals*: Table[SymId, Cursor]
    parent*: TypeScope

  MainModule* = object
    src*: TokenBuf
    pool*: Pool
    tags*: TagPool
    types*: seq[Cursor]                  ## points into MainModule.src
    filename*: string
    config*: ConfigRef
    mem*: seq[TokenBuf]                  ## intermediate results (computed types)
    builtinTypes*: Table[string, Cursor]
    current*: TypeScope
    defs: Table[SymId, Definition]
    typeBodyToDecl: Table[int, Cursor]   ## body `toUniqueId` -> its `(type …)` decl
    prog: NifProgram
    requestedForeignSyms*: seq[Cursor]

proc loadForeign(c: var MainModule; s: SplittedSymName): Cursor =
  ## Resolve a foreign symbol's declaration through the shared `ForeignModule`
  ## lazy loader: open (and cache) the owning module, then jump to the symbol's
  ## indexed offset and parse just that one decl. The cursor stays valid because
  ## the `ForeignModule` owns the per-decl buffer.
  if s.module == "":
    raiseAssert "Cannot lookup declaration without module name: " & s.name
  var m: ForeignModule
  if c.prog.mods.hasKey(s.module):
    m = getOrQuit(c.prog.mods, s.module)
  else:
    c.prog.scheme.name = s.module
    m = openForeignModule($c.prog.scheme)
    c.prog.mods[s.module] = m
  let key = $s
  if not hasDecl(m, key):
    raiseAssert "Symbol not found in NIF module: " & key
  result = getDecl(m, key, c.tags, c.pool)   # share the main module's pool (SymId-keyed)

proc registerForeignModule*(c: var MainModule; module: string; m: ForeignModule) =
  ## Pre-register a foreign module under its bare suffix, so `loadForeign` and
  ## `canLoadForeign` find it in the cache and never build a path for it. This is
  ## the seam a caller that already holds the imported module's bytes uses; the
  ## path-based lazy loading above stays the default and the fallback.
  c.prog.mods[module] = m

proc foreignModuleFromBuf*(content: sink string; module: string): ForeignModule =
  ## The buffer twin of `foreignmodules.openForeignModule`. Same shape: keep the
  ## reader open over the bytes and read the embedded index, so declarations are
  ## still materialized one at a time by index offset. Binary modules are not
  ## supported here — `bif` is mmap-only — and a caller holding bif bytes
  ## registers them through the path loader instead.
  ## Local to lengc until `src/lib/foreignmodules.nim` grows the twin; see
  ## `notes/a2a-lengc.md` section 6.
  result = ForeignModule(r: rd.openFromBuffer(ensureMove content, module),
                         index: initTable[string, int](),
                         decls: initTable[string, Cursor]())
  if indexStartsAt(result.r) > 0:
    result.hasEmbeddedIndex = true
    result.index = readEmbeddedIndex(result.r)

proc firstChild(c: Cursor): Cursor {.inline.} =
  result = c
  inc result

proc externName*(s: SymId; n: Cursor): StrId =
  ## Extract the importc/exportc name from a pragma node `n` (or fall back to the
  ## symbol's basename). Pool-free: uses the cursor's own buffer pool.
  let nn = firstChild(n)
  let p = n.pool
  if nn.kind == StrLit:
    result = p.strings.getOrIncl(strVal(nn, p))
  else:
    var base = p.syms[s]
    extractBasename base
    result = p.strings.getOrIncl(base)

proc extractExtern(c: var MainModule; n: var Cursor; pragmasAt: int;
                   isImport: var bool; bareImport: var bool): StrId =
  result = StrId(0)
  isImport = false
  bareImport = false
  var sawImportC = false
  var sawHeaderish = false
  n.into:  # enter the toplevel (type/proc/var/…)
    if n.kind != SymbolDef:
      raiseAssert "Expected SymbolDef after toplevel declaration"
    let symId = n.symId
    inc n
    for i in 1 ..< pragmasAt: skip n
    if n.substructureKind == PragmasU:
      n.into:
        while n.hasMore:
          let pk = n.pragmaKind
          if pk in {ImportcP, ImportcppP, ExportcP}:
            result = externName(symId, n)
            if pk in {ImportcP, ImportcppP}:
              isImport = true
            if pk == ImportcP:
              sawImportC = true
          elif pk in {HeaderP, NodeclP}:
            sawHeaderish = true
          skip n
    elif n.kind == DotToken:
      discard "ok"
    else:
      raiseAssert "pragmas not at the correct position"
    while n.hasMore:
      skip n
  bareImport = sawImportC and not sawHeaderish

proc registerTypeBody(c: var MainModule; declPos: Cursor) =
  ## Map a `(type …)` decl's body position to the decl, so `tracebackTypeC` can
  ## recover the decl from a body cursor without walking the buffer backwards.
  c.typeBodyToDecl[asTypeDecl(declPos).body.toUniqueId()] = declPos

proc tracebackTypeC*(c: var MainModule; n: Cursor): Cursor =
  ## The nifcore replacement for the nifcursors backward walk: given a type
  ## *body* cursor, return its enclosing `(type …)` declaration. Returns
  ## `default(Cursor)` for an unregistered body (e.g. an anonymous inline type).
  c.typeBodyToDecl.getOrDefault(n.toUniqueId(), default(Cursor))

proc canLoadForeign*(c: var MainModule; s: SymId): bool =
  ## True when `getDeclOrNil` would find a declaration for `s` — i.e. the owning
  ## module's file exists AND its embedded index names `s`. `getDeclOrNil`
  ## *asserts* on either failure, which is right for a consumer that needs the
  ## declaration to proceed; a consumer that is merely ASKING (an optimizer
  ## looking for a function summary) needs "no" to be an answer. Warms the
  ## module cache, so a following `getDeclOrNil` costs one table hit.
  if c.defs.hasKey(s): return true
  let splitted = splitSymName(c.pool.syms[s])
  if splitted.module == "": return false
  var m: ForeignModule
  if c.prog.mods.hasKey(splitted.module):
    m = getOrQuit(c.prog.mods, splitted.module)
  else:
    c.prog.scheme.name = splitted.module
    if not vfsExists($c.prog.scheme): return false
    m = openForeignModule($c.prog.scheme)
    c.prog.mods[splitted.module] = m
  result = hasDecl(m, $splitted)

proc getDeclOrNil*(c: var MainModule; s: SymId): ptr Definition =
  if not c.defs.hasKey(s):
    let splitted = splitSymName(c.pool.syms[s])
    if splitted.module == "": return nil
    let pos = loadForeign(c, splitted)
    if firstChild(pos).kind == SymbolDef:
      let sk = pos.symKind
      var extern = StrId(0)
      var isImport = false
      var bareImport = false
      var n = pos
      case sk
      of TypeY:
        c.types.add pos
        registerTypeBody(c, pos)
        extern = extractExtern(c, n, 1, isImport, bareImport)
      of ProcY:
        extern = extractExtern(c, n, 3, isImport, bareImport)
      of VarY, ConstY, GvarY, TvarY:
        extern = extractExtern(c, n, 1, isImport, bareImport)
      else: discard
      c.defs[s] = Definition(pos: pos, kind: sk, extern: extern,
                             isImport: isImport, bareImport: bareImport)
      c.requestedForeignSyms.add pos
    else:
      raiseAssert "Expected SymbolDef after toplevel declaration"
  result = addr getOrQuit(c.defs, s)

proc getExtern*(c: var MainModule; s: SymId): StrId =
  let d = c.getDeclOrNil(s)
  result = if d != nil: d.extern else: StrId(0)

# ---- scopes ---------------------------------------------------------------

proc registerLocal*(c: var MainModule; s: SymId; typ: Cursor) =
  c.current.locals[s] = typ

proc openScope*(c: var MainModule) =
  c.current = TypeScope(locals: initTable[SymId, Cursor](), parent: c.current)

proc closeScope*(c: var MainModule) =
  c.current = c.current.parent

# ---- module loading -------------------------------------------------------

proc processToplevelDecl(c: var MainModule; n: var Cursor; kind: LengSym;
                         pragmasAt: int) =
  let decl = n
  let s = firstChild(decl).symId
  var isImport = false
  var bareImport = false
  let extern = extractExtern(c, n, pragmasAt, isImport, bareImport)
  c.defs[s] = Definition(pos: decl, kind: kind, extern: extern,
                         isImport: isImport, bareImport: bareImport)

proc detectToplevelDecls(c: var MainModule) =
  var n = cursorAt(c.src, 0)
  if n.kind != TagLit: return
  # the src buffer starts with a (stmts …) wrapper; walk its children.
  n.into:
    while n.hasMore:
      if n.kind == TagLit:
        case n.stmtKind
        of TypeS:
          c.types.add n
          registerTypeBody(c, n)
          processToplevelDecl(c, n, TypeY, 1)
        of ProcS:
          processToplevelDecl(c, n, ProcY, 3)
        else:
          case n.symKind
          of VarY, ConstY, GvarY, TvarY:
            processToplevelDecl(c, n, n.symKind, 1)
          else:
            skip n
      else:
        inc n

type
  DensifyRemap = object
    ## Id translation for densifying a buffer whose pools differ from `dest`'s
    ## (the `.bif` load path: bif mints fresh pools — its INVARIANT — while the
    ## backends need the canonical Leng tag pool for `stmtKind` & co to decode).
    ## Inactive (empty `tagMap`) when source and dest share pools: densify's
    ## string-based re-adds (`strVal`/`symName` resolve against the *cursor's*
    ## pool) are already cross-pool safe; only the two raw ids — the `TagId`
    ## passed to `openTag` and the `FileId`/comment inside a `NifLineInfo` —
    ## need mapping.
    tagMap: seq[TagId]     # source TagId -> dest TagId; 1-based, [0] unused
    fileMap: seq[FileId]   # source FileId -> dest FileId; 1-based, [0] unused
    srcPool: Pool          # for re-interning the rare line-info comment StrId

proc buildDensifyRemap(dest: var TokenBuf; src: TokenBuf): DensifyRemap =
  result = DensifyRemap(srcPool: src.pool)
  result.tagMap = newSeq[TagId](src.tags.tags.len + 1)
  for i in 1 .. src.tags.tags.len:
    result.tagMap[i] = dest.tags.registerTag(src.tags.tags[TagId(i)])
  result.fileMap = newSeq[FileId](src.pool.filenames.len + 1)
  for i in 1 .. src.pool.filenames.len:
    result.fileMap[i] = dest.pool.filenames.getOrIncl(src.pool.filenames[FileId(i)])

proc mapInfo(dest: var TokenBuf; info: NifLineInfo; remap: DensifyRemap): NifLineInfo =
  result = info
  if remap.tagMap.len > 0 and info.isValid:
    result.file = remap.fileMap[int info.file]
    if result.comment != StrId(0):
      result.comment = dest.pool.strings.getOrIncl(remap.srcPool.strings[result.comment])

proc densify(dest: var TokenBuf; n: var Cursor; cur: var NifLineInfo;
             remap: DensifyRemap) =
  ## Copy the tree at `n` into `dest`, stamping *every* head token with its
  ## effective line info. nifcore stores line info sparsely (only when it
  ## changes); the nifcursors world propagated it to every node, and the
  ## backends rely on `info(n)` being valid at each statement/expression (e.g.
  ## LLVM `!dbg` / C `#line`). Densifying once at load restores that invariant
  ## for all backends with no per-call-site changes. `cur` is the running
  ## sequential (depth-first) line info, matching how nifcursors propagated it —
  ## a node inherits the most recent info *in stream order*, not its parent's.
  let raw = rawLineInfo(n)
  if raw.isValid: cur = raw
  let eff = mapInfo(dest, cur, remap)
  case n.kind
  of TagLit:
    var tag = n.cursorTagId
    if remap.tagMap.len > 0: tag = remap.tagMap[int tag]
    dest.openTag tag
    if eff.isValid: dest.appendLineInfo eff
    n.into:
      while n.hasMore: densify(dest, n, cur, remap)
    dest.closeTag()
  of DotToken:
    dest.addDotToken();          (if eff.isValid: dest.appendLineInfo eff); inc n
  of Ident:
    dest.addIdent strVal(n);     (if eff.isValid: dest.appendLineInfo eff); inc n
  of Symbol:
    dest.addSymUse symName(n);   (if eff.isValid: dest.appendLineInfo eff); inc n
  of SymbolDef:
    dest.addSymDef symName(n);   (if eff.isValid: dest.appendLineInfo eff); inc n
  of StrLit:
    dest.addStrLit strVal(n);    (if eff.isValid: dest.appendLineInfo eff); inc n
  of CharLit:
    dest.addCharLit charLit(n);  (if eff.isValid: dest.appendLineInfo eff); inc n
  of IntLit:
    dest.addIntLit intVal(n);    (if eff.isValid: dest.appendLineInfo eff); inc n
  of UIntLit:
    dest.addUIntLit uintVal(n);  (if eff.isValid: dest.appendLineInfo eff); inc n
  of FloatLit:
    dest.addFloatLit floatVal(n);(if eff.isValid: dest.appendLineInfo eff); inc n
  of ExtendedSuffix, LineInfoLit, UnknownToken, EofToken, ParLe, ParRi:
    inc n  # absorbed into the head token's own value/info; never freestanding

proc looksLikeBif*(content: string): bool =
  ## `bif.isBifFile` over bytes we already hold. The file probe opens the path
  ## with the raw `syncio` API, so it cannot answer for a buffer at all; it
  ## compares the same six magic name bytes and deliberately ignores
  ## endianness/version so a wrong-version binary module still reaches `load`
  ## and gets its precise diagnostic. See `notes/a2a-lengc.md` section 6 for the
  ## shared-library version this wants to become.
  const Magic = "NIFBIN"
  result = content.len >= Magic.len
  if result:
    for i in 0 ..< Magic.len:
      if content[i] != Magic[i]: return false

proc loadFromBuf*(raw: var TokenBuf; filename: string; fromBif = false): MainModule =
  ## The buffer half of `load`: everything after the input has been parsed into
  ## `raw`. `filename` is the module's *logical* path — it names the module
  ## (`splitModulePath`) and, through `prog.scheme`, the directory and extension
  ## every foreign module is looked for under, so a caller working entirely from
  ## buffers still passes the path the input would have had.
  ##
  ## Densifies line info so `info(n)` is valid at every node (see `densify`).
  ## The densified buffer shares `raw`'s pool/tags in the text case; in the bif
  ## case it gets its own canonical pools and `DensifyRemap` translates the raw
  ## ids (tags, line-info FileIds) — strings/symbols re-intern by value anyway.
  result = MainModule(current: TypeScope(locals: initTable[SymId, Cursor]()),
                      filename: filename,
                      prog: NifProgram(scheme: splitModulePath(filename)))
  var remap = default(DensifyRemap)
  if fromBif:
    result.src = createTokenBuf(raw.len, nil, createLengTagPool())
    remap = buildDensifyRemap(result.src, raw)
  else:
    result.src = createTokenBuf(raw.len, raw.pool, raw.tags)
  var rc = beginRead(raw)
  var curInfo = NoNifLineInfo
  densify(result.src, rc, curInfo, remap)
  result.pool = result.src.pool
  result.tags = result.src.tags
  detectToplevelDecls(result)

proc parseFromBuf*(content: sink string; filename: string): TokenBuf =
  ## Parse textual NIF held in memory. The tag pool is the canonical Leng one so
  ## interned TagIds equal the master ordinals that `stmtKind`/`typeKind`/
  ## `symKind` decode against — the same invariant the file path relies on.
  let nodeCount = content.len div 7
  var r = rd.openFromBuffer(ensureMove content, rd.extractModuleSuffix(filename))
  case rd.processDirectives(r)
  of rd.Success: discard
  of rd.WrongHeader: quit "nif files must start with Version directive"
  of rd.WrongMeta: quit "the format of meta information is wrong!"
  result = createTokenBuf(nodeCount, nil, createLengTagPool())
  nifcoreparse.parse(r, result)
  rd.close(r)

proc readSource*(filename: string): string =
  ## The module's bytes, kept apart from the parse so a driver can time loading
  ## and parsing separately (`JIT_IMPL.md` A2a). A binary module comes back as
  ## the empty string: `bif.load` mmaps the file itself, zero-copy, and reading
  ## it here would only cost a second copy — `parseSource` re-opens it by path.
  if not vfsExists(filename):
    # The same diagnostic `nifreader.open` gave when it did the opening.
    quit "[Error] cannot open: " & filename
  if isBifFile(filename): result = ""
  else: result = vfsRead(filename)

proc parseSource*(content: sink string; filename: string): MainModule =
  ## The parse half of `load`, over bytes `readSource` produced. An empty
  ## `content` for an existing binary module means "mmap it yourself".
  var fromBif = false
  var raw = default(TokenBuf)
  if content.len == 0 and isBifFile(filename):
    fromBif = true
    var bm = bif.load(filename)  # mmap; the index is not needed here, we rescan
    raw = ensureMove bm.buf
  elif looksLikeBif(content):
    # A binary module handed over as bytes: bif's own loader is path-based, so
    # spill it back through the mmap route rather than decode it here.
    fromBif = true
    var bm = bif.load(filename)
    raw = ensureMove bm.buf
  else:
    raw = parseFromBuf(ensureMove content, filename)
  result = loadFromBuf(raw, filename, fromBif)

proc load*(filename: string): MainModule =
  ## Load the main module, sniffing the file header for the actual format:
  ## filenames stay `.nif` throughout the pipeline, the content decides.
  result = parseSource(readSource(filename), filename)
