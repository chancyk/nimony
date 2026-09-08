#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Is this edit reloadable, or does the guest have to restart? — JIT.md 7.4's
## classifier.
##
## > Safe: non-inline body edits, new procs, new globals (append-only data
## > arena). Unsafe, detected: signature changes (interface checksum), type
## > layout changes (per-module `(layouts …)` sidecar from nifasm's `typesem`),
## > changed global initializers, the main module's top level, changed
## > thread-local set.
##
## The answer has to be a REASON, not a bool. A restart that happens without
## saying why is the failure mode `nimony dev` exists to avoid: the user edits a
## file, the program starts over, and nothing tells them whether that was the
## signature they changed or a bug in the reloader.
##
## What it reads, and why that and not the sidecar
## -----------------------------------------------
##
## Every module's `<mod>.c.nif` — hexer's output, arkham's input — walked once
## per build and reduced to one record per top-level declaration: its TAG, a
## digest of its header, and a digest of its body.
##
## The obvious alternative is F1's `<mod>.decls.nif`, which already carries a
## line-info-blind digest per declaration and is written by the build anyway.
## It is not enough on its own, and the gap is exactly the thing this phase has
## to detect: `DeclDigest` has `input` and `output` and no notion of a
## declaration's KIND or of the line between a proc's signature and its body.
## "The whole declaration changed" cannot tell a body edit from a signature
## edit, and those are the two answers. Splitting the digest in
## `hexer/decldigest.nim` would be the efficient home for this and is the
## follow-up (`notes/b4.md`); doing it here first keeps the phase off the
## frontend's output format, which `decl-stability` pins.
##
## The digest itself IS `decldigest.digestTree`, so this file inherits F1's
## line-info blindness rather than re-deriving it: an edit that inserts a line
## must not make every declaration below it look changed.
##
## Soundness, stated plainly
## -------------------------
##
## A reload replaces the CODE of named procs and nothing else: the guest's data
## region keeps its bytes and its addresses (`devhost.nim`). So a reload is
## sound exactly when the new build's data layout is the one the live image
## already has. This says yes only when **every** changed declaration in
## **every** module is a proc whose header is unchanged, and no declaration of
## any other kind was added, removed or changed anywhere. That is stricter than
## JIT.md's list in two places, and both are deliberate:
##
## * **a new global is a restart here**, where JIT.md allows it against an
##   "append-only data arena". The arena this loads into is not append-only:
##   `layInMemory` computes every global's offset from the whole module set, so
##   one more global moves the ones after it.
## * **a new or removed TYPE is a restart** even when no layout moved. That is
##   what the `(layouts …)` sidecar JIT.md names would buy back, and it is not
##   needed for soundness — only for saying yes more often.

import std / [os, tables, algorithm, strutils, assertions]

include ".." / lib / nifprelude
import ".." / lib / symparser
import ".." / hexer / decldigest

type
  DeclKind* = enum
    dkProc     ## code, and the only kind a reload can replace
    dkType     ## a layout, or something a layout is computed from
    dkGvar     ## a global: an address in the data region, and an initializer
    dkOther    ## a const, an import, anything else at the top level

  DeclEntry* = object
    ## One top-level declaration of one module, reduced to what the verdict
    ## needs. `body` is empty for everything but a proc, because the split only
    ## means something there.
    sym*: string
    kind*: DeclKind
    header*: string
    body*: string

  ModuleDigest* = object
    module*: string          ## the module's suffix, i.e. its `.c.nif` stem
    decls*: seq[DeclEntry]   ## sorted by `sym`, so two builds compare in order

  ProgramDigest* = object
    ## Every module of one build. Sorted by module name for the same reason.
    modules*: seq[ModuleDigest]

  ReloadVerdict* = enum
    rvUnchanged   ## nothing a reload would have to do
    rvReload      ## replace these procs' code; the data region stays
    rvRestart     ## `reason` says what made it one

  ReloadPlan* = object
    verdict*: ReloadVerdict
    reason*: string
      ## For `rvRestart`, one sentence naming the declaration and what about it
      ## changed. This is the gate's second half; it is not a nicety.
    changed*: seq[string]
      ## For `rvReload`, the procs whose code must be redirected, by their full
      ## NIF symbol — which is also their nifasm name and their key in
      ## `MemImage.procs`.

const
  CNifExt = ".c.nif"

proc kindOfTag(tag: string): DeclKind =
  case tag
  of "proc", "func", "macro", "converter", "method": dkProc
  of "type": dkType
  of "gvar", "var", "tvar", "threadvar": dkGvar
  else: dkOther

proc headerAndBody(n0: Cursor; kind: DeclKind;
                   header, body: var string) =
  ## Split one declaration into "what callers can see" and "what only it can
  ## see", and digest each.
  ##
  ## A Leng proc is `(proc :sym <exported> <pattern> <typevars> <params>
  ## <rettype> <pragmas> <effects> <body>)` -- the body is the LAST child, so
  ## the header is every child before it. Digesting the children one at a time
  ## and mixing the strings, rather than digesting a rebuilt subtree, is what
  ## keeps this from having to construct a token buffer per declaration on
  ## every rebuild.
  ##
  ## For anything that is not a proc the whole declaration is the header: a
  ## type IS its layout and a global IS its address and initializer, so there
  ## is no half of either that a reload could leave alone.
  header = ""
  body = ""
  if kind != dkProc:
    header = digestTree(n0)
    return
  var n = n0
  if not n.isTagLit:
    header = digestTree(n0)
    return
  var kids: seq[Cursor] = @[]
  n.into:
    while n.hasMore:
      kids.add n
      skip n
  if kids.len == 0:
    header = digestTree(n0)
    return
  var h = ""
  for i in 0 ..< kids.len - 1:
    h.add digestTree(kids[i])
    h.add '/'
  header = h
  body = digestTree(kids[^1])

proc digestModule(file: string): ModuleDigest =
  ## One `<mod>.c.nif`. A child of the root `(stmts …)` with no `SymbolDef` is
  ## skipped for the reason `decldigest.digestToplevel` skips it: it has no key
  ## that survives an edit above it, and a positional key would report "changed"
  ## for exactly the reason F1 exists to stop reporting it.
  result = ModuleDigest(module: file.extractFilename.replace(CNifExt, ""),
                        decls: @[])
  var buf = parseFromFile(file)
  var n = beginRead(buf)
  if not n.isTagLit: return
  n.into:
    while n.hasMore:
      if n.isTagLit:
        let tag = globalTags.tags[n.cursorTagId]
        var head = n
        inc head
        if head.isSymbolDef:
          let kind = kindOfTag(tag)
          var e = DeclEntry(sym: pool.symString(head.symId), kind: kind,
                            header: "", body: "")
          headerAndBody(n, kind, e.header, e.body)
          result.decls.add e
      skip n
  # Sorted so that two builds walk the same order and a missing symbol shows up
  # as a gap rather than as an offset.
  result.decls.sort(proc (a, b: DeclEntry): int =
    if a.sym < b.sym: -1 elif a.sym > b.sym: 1 else: 0)

proc digestProgram*(backendDir: string): ProgramDigest =
  ## Every `<mod>.c.nif` in the backend directory, i.e. the whole program as
  ## arkham will see it.
  result = ProgramDigest(modules: @[])
  var files: seq[string] = @[]
  for kind, f in walkDir(backendDir):
    if kind == pcFile and f.endsWith(CNifExt): files.add f
  files.sort()
  for f in files: result.modules.add digestModule(f)

proc kindName(k: DeclKind): string =
  case k
  of dkProc: "proc"
  of dkType: "type"
  of dkGvar: "global"
  of dkOther: "declaration"

proc isModuleInit(sym: string): bool =
  ## The synthesized module initializer, whose body IS the module's top level.
  ## nimony spells it `` `ini `` (`symparser.sourceIdent` strips the quote), and
  ## JIT.md 7.4 lists "the main module's top level" among the UNSAFE edits: a
  ## reload does not re-run it, so redirecting it would replace code that has
  ## already run and change nothing the user can see -- the worst possible
  ## outcome, since it looks like it worked.
  let ident = sourceIdent(sym)
  result = ident == "ini" or ident.endsWith(".ini")

proc classify*(before, after: ProgramDigest): ReloadPlan =
  ## The verdict, and either the procs to redirect or the reason not to.
  ##
  ## Modules are compared as a set first: a module that appeared or vanished
  ## changes the whole program's data layout, so it is a restart before any
  ## declaration is looked at.
  result = ReloadPlan(verdict: rvUnchanged, reason: "", changed: @[])
  var old = initTable[string, ModuleDigest]()
  for m in before.modules: old[m.module] = m
  var fresh = initTable[string, ModuleDigest]()
  for m in after.modules: fresh[m.module] = m

  for m in after.modules:
    if not old.hasKey(m.module):
      return ReloadPlan(verdict: rvRestart,
        reason: "the module " & m.module & " is new; a module the live image " &
                "does not have cannot be added to it", changed: @[])
  for m in before.modules:
    if not fresh.hasKey(m.module):
      return ReloadPlan(verdict: rvRestart,
        reason: "the module " & m.module & " is gone", changed: @[])

  for m in after.modules:
    let b = old[m.module]
    var was = initTable[string, DeclEntry]()
    for d in b.decls: was[d.sym] = d
    var isNow = initTable[string, DeclEntry]()
    for d in m.decls: isNow[d.sym] = d

    for d in m.decls:
      if not was.hasKey(d.sym):
        # A new PROC is safe: the relayed image contains it, and whatever calls
        # it is itself a changed proc that gets redirected into that image. A
        # new anything else moves the data region.
        if d.kind == dkProc: continue
        return ReloadPlan(verdict: rvRestart,
          reason: "a new " & kindName(d.kind) & ", " & sourceIdent(d.sym) &
                  ", changes the data layout the live image was built with",
          changed: @[])
      let w = was[d.sym]
      if w.kind != d.kind:
        return ReloadPlan(verdict: rvRestart,
          reason: sourceIdent(d.sym) & " changed from a " & kindName(w.kind) &
                  " to a " & kindName(d.kind), changed: @[])
      if w.header == d.header and w.body == d.body: continue
      if d.kind != dkProc:
        return ReloadPlan(verdict: rvRestart,
          reason: "the " & kindName(d.kind) & " " & sourceIdent(d.sym) &
                  " changed; a reload replaces code, not data",
          changed: @[])
      if w.header != d.header:
        return ReloadPlan(verdict: rvRestart,
          reason: "the signature of " & sourceIdent(d.sym) & " changed",
          changed: @[])
      if isModuleInit(d.sym):
        return ReloadPlan(verdict: rvRestart,
          reason: "the top level of " & m.module & " changed; a reload does " &
                  "not re-run a module's initializer",
          changed: @[])
      result.changed.add d.sym

    for d in b.decls:
      if not isNow.hasKey(d.sym):
        if d.kind == dkProc: continue     # nothing calls it any more
        return ReloadPlan(verdict: rvRestart,
          reason: "the " & kindName(d.kind) & " " & sourceIdent(d.sym) &
                  " is gone", changed: @[])

  if result.changed.len > 0:
    result.changed.sort()
    result.verdict = rvReload
