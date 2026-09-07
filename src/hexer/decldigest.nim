#
#
#           Hexer Compiler
#        (c) Copyright 2025 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## Declaration identity that does not depend on WHERE the declaration is.
##
## B3b re-lowers only the top-level declarations whose sem output changed, and
## the question it has to answer per declaration is "did this change", not "did
## this move". Those are not the same question in NIF: every declaration
## anchors its own line info, so an edit that inserts a line rewrites the `@…`
## suffix of every declaration below it in the same file even though nothing
## about them changed. `notes/b3b.md` measured 277 of `sem.nim`'s 1228
## declarations "changed" for a two-statement insertion, 49 of which survived a
## crude textual strip of the info.
##
## Two things live here:
##
## * `digestToplevel` — a per-declaration digest that is blind to line info,
##   because it hashes the TOKEN STREAM rather than the serialized bytes: a
##   `Cursor` steps over the `LineInfoLit` suffix as part of ordinary
##   structural navigation, so a walk that never asks for `.info` cannot see
##   it. Every content-addressed cache in the tree so far hashes text, which is
##   exactly what carries the position.
##
##   `nifchecksums.computeChecksum(Cursor)` already walks a subtree this way
##   and is the obvious thing to reuse; it is not used here because it is
##   SHA-1 and allocates a string per numeric literal. This digest runs over
##   every declaration of every module of every build, and measured at 0.43 s
##   of a 13 s cold self-compile -- 3.3 %, for something no consumer reads
##   yet. `DeclHash` below is the same walk over the same content with a
##   two-lane 128-bit multiplicative hash and no allocation.
##
## * `rebaseLineInfo` — the inverse operation for the splice side: when a
##   previous run's fragment is reused for a declaration that has since moved,
##   its line info has to be brought to the new position. This is deliberately
##   NOT a blanket "add delta to the subtree": a declaration's tokens can carry
##   info from OTHER files (a generic body is copied verbatim from its
##   declaring module by `sem.subs`, keeping that module's positions) and from
##   FORGED filenames whose text embeds a declaration line
##   (`comesfrom`/`templates.nim`'s `--inlineframes` frames). Both are left
##   alone and counted, so a caller can refuse the splice instead of shifting
##   something it does not understand.
##
## Nothing here changes `.x.nif`: the digests go to a `<mod>.decls.nif`
## sidecar, a third output beside `.x.nif` and `.dce.nif`.

import std / [assertions, tables, algorithm]
include ".." / lib / nifprelude
import ".." / lib / comesfrom

type
  DeclDigest* = object
    sym*: string          ## the declaration's symbol, module suffix and all
    input*: string        ## line-info-blind digest of its sem input, "" if none
    output*: string       ## line-info-blind digest of its lowering output, "" if none

  ModuleDecls* = object
    decls*: seq[DeclDigest]
      ## one entry per named top-level declaration, sorted by symbol name so
      ## that two runs which computed the same thing produce the same bytes and
      ## `OnlyIfChanged` can mean something (the P0c lesson, `notes/p0c.md`).

# ── The digest ────────────────────────────────────────────────────────────

type
  DeclHash* = object
    ## Two independent multiplicative lanes over the same byte stream, 128 bits
    ## of answer. Custom code rather than `std/hashes` for the reason
    ## `src/lib/tinyhashes.nim` gives for `uhash`: the value ends up in a file,
    ## so it must not move when the host Nim's hashing does. 128 bits because
    ## the question it answers is "is this declaration the one I lowered last
    ## time" and a false yes is a miscompile, not a slow path -- at 64 bits a
    ## whole-program 200k declarations would collide about once in 10^9 builds,
    ## which is small but not a number worth carrying for free.
    a, b: uint64

const
  # Lane A is FNV-1a/64 (xor then multiply). Lane B is an add-multiply-shift
  # with the golden-ratio odd multiplier, so a pair of inputs that cancels in
  # one lane does not cancel in the other.
  HashSeedA = 0xcbf29ce484222325'u64
  HashSeedB = 0x9ae16a3b2f90404f'u64
  HashMulA = 0x00000100000001B3'u64
  HashMulB = 0x9e3779b97f4a7c15'u64

proc initDeclHash(): DeclHash {.inline.} =
  DeclHash(a: HashSeedA, b: HashSeedB)

proc mix(h: var DeclHash; x: uint64) {.inline.} =
  h.a = (h.a xor x) * HashMulA
  h.b = (h.b + x) * HashMulB
  h.b = h.b xor (h.b shr 29)

proc mixStr(h: var DeclHash; s: string) =
  for c in items(s): mix(h, uint64(uint8(c)))
  mix(h, 0xFF'u64)   # a terminator, so "ab"+"c" and "a"+"bc" differ

proc finish(x: uint64): uint64 {.inline.} =
  ## splitmix64's finalizer: the lanes above are weak in their high bits on
  ## their own, and the digest is read as hex from the top down.
  var z = x
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  result = z xor (z shr 31)

const HexDigits = "0123456789ABCDEF"

proc addHex(s: var string; x: uint64) =
  var i = 60
  while i >= 0:
    s.add HexDigits[int((x shr uint64(i)) and 0xF'u64)]
    dec i

proc `$`(h: DeclHash): string =
  result = newStringOfCap(32)
  result.addHex finish(h.a)
  result.addHex finish(h.b)

proc hashTree(n: var Cursor; h: var DeclHash) =
  ## The one place that decides what a declaration IS. Every branch mixes a
  ## distinct leading tag byte so that no two kinds can alias, and no branch
  ## reads `n.info` -- which is the whole point.
  if n.isTagLit:
    mix(h, 1); mixStr(h, globalTags.tags[n.cursorTagId])
    n.into:
      while n.hasMore:
        hashTree(n, h)
    mix(h, 2)
  else:
    if n.isSymbolDef: mix(h, 3); mixStr(h, pool.syms[n.symId])
    elif n.isSymbol: mix(h, 4); mixStr(h, pool.syms[n.symId])
    elif n.isIdent: mix(h, 5); mixStr(h, pool.strings[n.strId])
    elif n.isStringLit: mix(h, 6); mixStr(h, pool.strings[n.strId])
    elif n.isIntLit: mix(h, 7); mix(h, cast[uint64](n.intVal))
    elif n.isUIntLit: mix(h, 8); mix(h, n.uintVal)
    elif n.isFloatLit: mix(h, 9); mix(h, cast[uint64](n.floatVal))
    elif n.isCharLit: mix(h, 10); mix(h, uint64(n.uoperand))
    elif n.isDotToken: mix(h, 11)
    else: mix(h, 12)
    inc n

proc digestTree*(n0: Cursor): string =
  ## The line-info-blind digest of one subtree, rendered.
  var n = n0
  var h = initDeclHash()
  hashTree(n, h)
  result = $h

type
  DeclHashes* = Table[SymId, DeclHash]
    ## Keyed by `SymId`, not by name: this is built for every declaration of
    ## every module of every build, and a name key would copy the symbol string
    ## twice per declaration for nothing. The names are needed once, in
    ## `merge`, to sort.

proc digestToplevel*(n0: Cursor; dest: var DeclHashes) =
  ## Digest every top-level declaration of a module buffer, keyed by its
  ## `SymbolDef`.
  ##
  ## A child of the root `(stmts …)` with no `SymbolDef` — a comment node, an
  ## anonymous hoisted node — has no key that survives an edit above it, so it
  ## is skipped rather than keyed by position: a position key would answer
  ## "changed" for exactly the reason this module exists to stop answering it.
  var n = n0
  if not n.isTagLit: return
  n.into:
    while n.hasMore:
      if n.isTagLit:
        var head = n
        inc head
        if head.isSymbolDef:
          var sub = n
          var h = initDeclHash()
          hashTree(sub, h)
          dest[head.symId] = h
      skip n

proc cmpNames(a, b: string): int =
  ## `sort` needs an explicit comparator under Nimony, whose stdlib has no
  ## generic `cmp`. Same idiom as `dce1.cmpSymNames` and `deps.cmpNames`.
  if a < b: -1 elif a > b: 1 else: 0

proc merge*(input, output: DeclHashes): ModuleDecls =
  ## Join the two per-symbol digest maps into the sidecar's sorted list. A
  ## symbol hexer synthesized has no input digest; one hexer deleted has no
  ## output digest. Both are recorded, because "this symbol has no lowering
  ## any more" is an answer B3b needs.
  var syms = newSeq[SymId](0)
  for s in input.keys: syms.add s
  for s in output.keys:
    if not input.hasKey(s): syms.add s
  var names = newSeq[string](syms.len)
  for i in 0 ..< syms.len: names[i] = pool.syms[syms[i]]
  sort names, cmpNames
  var bySym = initTable[string, SymId]()
  for s in syms: bySym[pool.syms[s]] = s
  result = ModuleDecls(decls: newSeq[DeclDigest](0))
  for n in names:
    let s = bySym.getOrDefault(n)
    result.decls.add DeclDigest(
      sym: n,
      input: (if input.hasKey(s): $input.getOrDefault(s) else: ""),
      output: (if output.hasKey(s): $output.getOrDefault(s) else: ""))

const
  DeclTag = "decl"

proc writeDeclDigests*(outputFilename: string; m: ModuleDecls;
                       dottedSuffix: string) =
  ## Serialize one `ModuleDecls` as `<mod>.decls.nif`, beside `.x.nif` and
  ## `.dce.nif`. Symbols are abbreviated against `dottedSuffix` exactly as
  ## `dce1.writeAnalysis` does, and the write is `OnlyIfChanged` so an
  ## unchanged module keeps its mtime.
  var b = nifbuilder.open(outputFilename, writeMode = OnlyIfChanged)
  b.withTree "stmts":
    for d in m.decls:
      b.withTree DeclTag:
        b.addSymbol d.sym, dottedSuffix
        b.addStrLit d.input
        b.addStrLit d.output
  b.close()

proc parseDeclDigests*(n0: Cursor): ModuleDecls =
  ## The buffer-level reader, the exact inverse of `writeDeclDigests`.
  result = ModuleDecls(decls: newSeq[DeclDigest](0))
  var n = n0
  if not n.isTagLit: return
  n.into:
    while n.hasMore:
      if n.isTagLit:
        var d = DeclDigest()
        n.into:
          if n.hasMore and n.isSymbol:
            d.sym = pool.syms[n.symId]
            inc n
          if n.hasMore and n.isStringLit:
            d.input = pool.strings[n.strId]
            inc n
          if n.hasMore and n.isStringLit:
            d.output = pool.strings[n.strId]
            inc n
          while n.hasMore: skip n
        if d.sym.len > 0: result.decls.add d
      else:
        skip n

# ── Re-basing a spliced fragment ──────────────────────────────────────────

type
  RebaseStats* = object
    moved*: int    ## tokens whose line was shifted
    foreign*: int  ## tokens positioned in another file, left alone
    forged*: int   ## tokens on a `comesfrom` composite filename, left alone

proc rebased(info: NifLineInfo; path: string; delta: int32;
             s: var RebaseStats): NifLineInfo =
  ## The per-token decision. A token is shifted only when it names the moved
  ## file DIRECTLY: a composite `comesfrom` filename carries the template's
  ## declaration line inside its own text (`comesfrom.addCrucialInfo`), so
  ## shifting the numeric field alone would leave that text stale and the two
  ## halves disagreeing.
  result = info
  if not info.isValid: return
  let fname = pool.filenames[info.file]
  if isCrucialFile(fname):
    inc s.forged
    return
  if fname != path:
    inc s.foreign
    return
  result.line = info.line + delta
  inc s.moved

proc rebaseTree(n: var Cursor; dest: var TokenBuf; path: string; delta: int32;
                s: var RebaseStats) =
  if n.isTagLit:
    let tag = n.cursorTagId
    dest.addParLe(tag, rebased(n.info, path, delta, s))
    let endInfo = n.endInfo
    n.into:
      while n.hasMore:
        rebaseTree(n, dest, path, delta, s)
    dest.addParRi(rebased(endInfo, path, delta, s))
  else:
    let info = rebased(n.info, path, delta, s)
    if n.isSymbolDef: dest.addSymDef(n.symId, info)
    elif n.isSymbol: dest.addSymUse(n.symId, info)
    elif n.isIdent: dest.addIdent(n.strId, info)
    elif n.isStringLit: dest.addStrLit(n.strId, info)
    elif n.isIntLit: dest.addIntLit(n.intVal, info)
    elif n.isUIntLit: dest.addUIntLit(n.uintVal, info)
    elif n.isFloatLit: dest.addFloatLit(n.floatVal, info)
    elif n.isCharLit: dest.addCharLit(char(n.uoperand), info)
    else: dest.addDotToken(info)
    inc n

proc rebaseLineInfo*(n0: Cursor; dest: var TokenBuf; path: string;
                     delta: int32): RebaseStats =
  ## Copy the subtree at `n0` into `dest`, moving every token positioned in
  ## `path` by `delta` lines and leaving everything else exactly as it was.
  ## `delta` of 0 is the identity, which is what makes this testable against
  ## the un-rebased copy.
  result = RebaseStats()
  var n = n0
  rebaseTree(n, dest, path, delta, result)
