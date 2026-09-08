#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Replacing a proc's code while the guest is running it — JIT.md 7.4's swap.
##
## What a reload actually is
## -------------------------
##
## 1. The compiler assembles the whole edited program again. That is not a
##    concession: after B3d/B3e it is the cheap part (`self.editbody` assembles
##    in 0.09 s), and a whole image is the one thing that needs no new
##    machinery in arkham or nifasm.
## 2. This lays that image's CODE into free space further up the same arena,
##    and gives it the LIVE image's data region as its data ADDRESSES. The new
##    code therefore reads and writes the globals the running program already
##    has -- the counter it was incrementing keeps its value -- while its own
##    freshly-computed initializers are written to a scratch buffer and thrown
##    away. `MemRegion` separates `at` (where the bytes go now) from `vaddr`
##    (the address byte 0 will have), which is exactly the seam this needs and
##    is documented in `image/memory.nim` as existing for it.
## 3. The guest's stack is walked at a safepoint (`devwalk`). A proc with a live
##    frame is not replaced; the swap is deferred and retried at the next
##    safepoint.
## 4. Each replaced proc's ENTRY in the live image is overwritten with the same
##    12-byte `adrp x16 / ldr x16 / br x16` stub `image/hostfixup.emitA64Stub`
##    writes for an external call, jumping through a slot this allocates at the
##    top of the data region. The FIRST reload of a proc installs the stub; every
##    later one only rewrites the slot, so a proc becomes permanently indirect
##    the first time it is reloaded and costs one store thereafter.
##
## Why not JIT.md 7.3's "reloadable module -> slot indirection"
## -----------------------------------------------------------
##
## Because the `extproc` path it names does not provide it, and that was worth
## finding out before building on it (`notes/b4.md` §2):
##
## * arkham decides `extproc` from the Leng declaration alone -- an `importc`
##   with no body (`arkham/core/programs.nim`, `collect`'s `ProcS` branch). There
##   is no option, on the command line or on `Program`, that makes a proc WITH a
##   body external to its callers.
## * nifasm follows a foreign symbol into its module unconditionally
##   (`core/typesem.lookupWithAutoImport` -> `core/modules.openForeignModule`),
##   and a module it cannot find on disk is an `AsmError`, not an external.
##   There is no "do not follow into module X".
##
## So the build-time half of 7.3 is unbuilt in both tools. The run-time half --
## a call reaching its target through a writable slot -- is exactly what the
## stub above is, installed at the first reload instead of at every call site of
## a module somebody declared reloadable in advance. It is strictly more general
## (it catches intra-module direct calls too, which the extproc route would not)
## and it costs nothing for a program that never reloads.
##
## Platform
## --------
##
## macOS/arm64, which is where B4 is built (JIT_IMPL.md). The stub encoding is
## AArch64 and the frame-record walk is a Darwin ABI guarantee; x86-64 would
## want `emitIatCall`'s shape and the table's `cfaOff` step instead, which is
## B5's, and is refused by name here rather than mis-executed.

import std / [os, tables, strutils, posix]

import nifasm / [driver, hostrun]
import nifasm / core / asmerror
import nifasm / image / memory

import devwalk

when defined(macosx):
  proc sys_icache_invalidate(start: pointer; size: csize_t)
    {.importc, header: "<libkern/OSCacheControl.h>".}

type
  SwapOutcome* = enum
    swSwapped    ## the code is in; `generation` counts it
    swDeferred   ## a replaced proc has a live frame; ask again at the next poll
    swRefused    ## it cannot be done at all; `reason` says why

  SwapResult* = object
    outcome*: SwapOutcome
    generation*: int
    reason*: string
    stack*: string       ## the guest's stack at the safepoint, for `--verbose`

  DevSession* = object
    ## Everything one guest's hot-reload state is. Threaded through by `var`
    ## rather than kept in a global: the ONE thing that has to be a global is
    ## the C-ABI intercept's handle on it, and that lives in `nimrun`, where it
    ## is argued at its declaration.
    arena: Arena
    base: MemImage           ## the live image; its data region is the program's
    codeBump: int            ## next free byte of the code region, page-aligned
    slotBump: int            ## slots taken from the TOP of the data region
    tables: seq[TraceTable]  ## the base image's, then one per reload
    slots: Table[string, uint]   ## proc name -> its indirection slot's address
    generation*: int
    scratch: seq[byte]       ## where a relayed image's data bytes go to die
    ok: bool

proc pageSize(): int {.inline.} = int(sysconf(SC_PAGESIZE))

proc pageUp(x: int): int {.inline.} =
  let ps = pageSize()
  ((x + ps - 1) div ps) * ps

proc dataStart(a: Arena): uint {.inline.} =
  cast[uint](a.base) + uint(a.codeCap)

proc initDevSession*(arena: Arena; base: MemImage; d: var DevSession): string =
  ## "" when the session can reload, a diagnostic when it cannot. Refusing here,
  ## before the guest starts, is the difference between "this program is not
  ## reloadable" and a reload that fails in the middle of a session.
  d = DevSession(arena: arena, base: base, codeBump: 0, slotBump: 0,
                 tables: @[], slots: initTable[string, uint](),
                 generation: 0, scratch: @[], ok: false)
  when not (defined(macosx) and defined(arm64)):
    return "hot reload is implemented for macOS/arm64 only (JIT_IMPL.md B5 " &
           "has the other platforms)"
  if base.traceTable == 0:
    return "the image carries no stack-trace table, so a live frame cannot be " &
           "detected (`AsmSession.wantTraceTable`)"
  let t = openTraceTable(uint(base.traceTable))
  if t.count == 0:
    return "the image's stack-trace table is empty or unreadable"
  d.tables.add t
  # Code laid after the base image starts on a fresh page: the pages holding
  # the base image are already read+execute, and a relayed image has to be
  # WRITTEN before it is protected.
  d.codeBump = pageUp(base.codeLen)
  # The relayed image's data bytes are computed and thrown away, so the buffer
  # they go to is sized to the LIVE image's data region and no larger. Two
  # reasons, and the second is the important one: `newSeq` zeroes, so asking for
  # the arena's whole 64 MB data cap would touch 64 MB of real memory in every
  # dev session; and a relayed image whose data does not FIT this buffer is
  # exactly the "the data layout moved" case, so `layInMemory` refusing on the
  # cap is the check, not a hazard.
  d.scratch = newSeq[byte](pageUp(base.dataLen) + pageSize())
  d.ok = true
  result = ""

proc findAnyProc(d: DevSession; pc: uint): int =
  ## Which table, if any, has a row containing `pc`. Every generation's table
  ## stays: JIT.md 7.4's *"old code is never unmapped in a session"* means a
  ## frame can be in any of them, and a frame this cannot name is a frame whose
  ## liveness cannot be ruled out.
  for i in 0 ..< d.tables.len:
    if findProc(d.tables[i], pc) >= 0: return i
  result = -1

proc liveNames(d: DevSession; frames: GuestFrames): seq[string] =
  ## Every proc that has a frame on the guest's stack right now, by name, across
  ## every generation.
  result = @[]
  for pc in frames.pcs:
    for i in 0 ..< d.tables.len:
      let idx = findProc(d.tables[i], pc)
      if idx >= 0:
        let n = rowName(d.tables[i], idx)
        if n notin result: result.add n
        break

proc describeStack(d: DevSession; frames: GuestFrames): string =
  result = ""
  for pc in frames.pcs:
    var name = "?"
    for i in 0 ..< d.tables.len:
      let idx = findProc(d.tables[i], pc)
      if idx >= 0:
        name = rowName(d.tables[i], idx)
        break
    if result.len > 0: result.add " < "
    result.add name
  if frames.truncated: result.add " < ..."

proc writeStub(at: uint; slot: uint) =
  ## `image/hostfixup.emitA64Stub`'s three instructions, written straight into
  ## the live image instead of into a `Bytes` an image writer is building.
  ##
  ## Spelled out here rather than called across the repo boundary because the
  ## nativenif routine takes a `Bytes` and a byte offset -- it writes into an
  ## image under construction, and this writes into one that is running. The
  ## ENCODING is the same three words and is checked against it by name; if that
  ## one changes, so must this.
  ##
  ## x16 is IP0, the ABI's inter-procedural scratch register: it is dead at
  ## every call boundary, and a proc's first instruction is exactly one.
  let stubPage = at and not 0xFFF'u
  let slotPage = slot and not 0xFFF'u
  let pageDiff = int64(slotPage) - int64(stubPage)
  let pageOff = slot and 0xFFF'u
  let adrpImm = pageDiff shr 12
  let immlo = uint32(adrpImm and 0x03) shl 29
  let immhi = uint32((adrpImm shr 2) and 0x7FFFF) shl 5
  let w = cast[ptr UncheckedArray[uint32]](at)
  w[0] = 0x90000010'u32 or immlo or immhi                   # adrp x16, slot@PAGE
  w[1] = 0xF9400210'u32 or (uint32(pageOff shr 3) shl 10)   # ldr x16,[x16,#off]
  w[2] = 0xD61F0200'u32                                     # br x16

proc protectRange(at: uint; len: int; prot: cint): bool =
  ## `mprotect` over whatever pages `[at, at+len)` touches.
  let ps = uint(pageSize())
  let lo = at and not (ps - 1)
  let hi = ((at + uint(len)) + ps - 1) and not (ps - 1)
  result = mprotect(cast[pointer](lo), int(hi - lo), prot) == 0

proc allocSlot(d: var DevSession): uint =
  ## One 8-byte cell, taken from the TOP of the data region and growing down, so
  ## it can never meet an image's data, which grows up from the bottom.
  d.slotBump += 8
  result = dataStart(d.arena) + uint(d.arena.dataCap) - uint(d.slotBump)

proc redirect(d: var DevSession; name: string; target: uint64): string =
  ## Point `name` at `target`. "" on success.
  if not d.base.procs.hasKey(name):
    return "the live image has no proc called " & name
  let old = uint(d.base.procs[name])
  if d.slots.hasKey(name):
    # Already indirect: one store, no code written, no page re-protected.
    cast[ptr uint64](d.slots[name])[] = target
    return ""
  let slot = d.allocSlot()
  cast[ptr uint64](slot)[] = target
  if not protectRange(old, 12, PROT_READ or PROT_WRITE):
    return "could not make the live code writable to redirect " & name
  writeStub(old, slot)
  if not protectRange(old, 12, PROT_READ or PROT_EXEC):
    return "could not restore execute permission after redirecting " & name
  when defined(macosx):
    sys_icache_invalidate(cast[pointer](old), csize_t(12))
  d.slots[name] = slot
  result = ""

proc layRelay(d: var DevSession; sess: var AsmSession;
              img: var MemImage): string =
  ## Lay a freshly assembled whole-program session into free arena space with
  ## the LIVE data region as its data addresses. "" on success.
  let codeAt = cast[uint](d.arena.base) + uint(d.codeBump)
  if d.codeBump >= d.arena.codeCap:
    return "the arena's code region is full; old code is never unmapped in a " &
           "session, so a long dev session eventually restarts"
  let arena2 = MemArena(
    code: MemRegion(at: cast[pointer](codeAt), vaddr: uint64(codeAt),
                    cap: d.arena.codeCap - d.codeBump),
    data: MemRegion(at: addr d.scratch[0], vaddr: uint64(dataStart(d.arena)),
                    cap: d.scratch.len))
  try:
    img = layInMemory(sess.ctx, arena2)
  except AsmError as e:
    return "nifasm: " & e.msg
  except CatchableError as e:
    return "nifasm: " & e.msg

  # The check that licenses step 2: the relayed image has to agree with the live
  # one about where the data region is. `devclassify` proved it from the SOURCE;
  # this proves it from the two images, which is the half that would catch a
  # classifier that let something through.
  if img.dataLen != d.base.dataLen:
    return "the data region changed size (" & $d.base.dataLen & " -> " &
           $img.dataLen & "); the live globals are not where the new code " &
           "thinks they are"
  if img.externals.len != d.base.externals.len:
    return "the external symbol set changed (" & $d.base.externals.len &
           " -> " & $img.externals.len & ")"
  for i in 0 ..< img.externals.len:
    if img.externals[i].name != d.base.externals[i].name:
      return "the external symbol set changed at slot " & $i & " (" &
             d.base.externals[i].name & " -> " & img.externals[i].name & ")"

  if not protectRange(codeAt, img.codeLen, PROT_READ or PROT_EXEC):
    return "could not make the relayed code executable"
  when defined(macosx):
    sys_icache_invalidate(cast[pointer](codeAt), csize_t(img.codeLen))
  d.codeBump += pageUp(img.codeLen)
  if img.traceTable != 0:
    d.tables.add openTraceTable(uint(img.traceTable))
  result = ""

proc swap*(d: var DevSession; backendDir, mainModule, blobCacheDir: string;
           changed: seq[string]; res: var SwapResult) =
  ## The whole of a reload, called from the safepoint intercept and therefore
  ## ON THE GUEST'S THREAD, with the guest parked in a frame it called.
  res = SwapResult(outcome: swRefused, generation: d.generation, reason: "",
                   stack: "")
  if not d.ok:
    res.reason = "this session cannot reload"
    return
  if changed.len == 0:
    res.outcome = swSwapped
    return

  # The stack FIRST, before anything is assembled: a deferral costs nothing if
  # it is decided before the work.
  var frames = GuestFrames(pcs: @[], truncated: false)
  walkFromHere(uint(d.base.codeVaddr),
               uint(d.base.codeVaddr) + uint(d.arena.codeCap), frames)
  res.stack = describeStack(d, frames)
  if frames.truncated:
    res.outcome = swDeferred
    res.reason = "the guest's stack could not be walked to the end, so a live " &
                 "frame cannot be ruled out"
    return
  let live = liveNames(d, frames)
  var blocked: seq[string] = @[]
  for c in changed:
    if c in live and c notin blocked: blocked.add c
  if blocked.len > 0:
    res.outcome = swDeferred
    res.reason = "a frame of " & blocked.join(", ") & " is live"
    return

  var sess = default(AsmSession)
  var haveSession = false
  var img = default(MemImage)
  let mainAsm = backendDir / mainModule & ".asm.nif"
  if not fileExists(mainAsm):
    res.reason = "the rebuild produced no " & mainModule & ".asm.nif"
    return
  try:
    sess = openFileSession(mainAsm, debugInfo = false, singleThread = true)
    haveSession = true
    sess.wantTraceTable = true
    sess.useBlobCache(blobCacheDir)
    sess.declare()
    sess.beginEmit()
    sess.emitTopLevel()
    sess.emitRoots()
    sess.finishCode()
    sess.saveBlobCache()
  except AsmError as e:
    if haveSession: sess.closeSession()
    res.reason = "nifasm: " & e.msg
    return
  except CatchableError as e:
    if haveSession: sess.closeSession()
    res.reason = "nifasm: " & e.msg
    return

  let bad = layRelay(d, sess, img)
  if bad.len > 0:
    sess.closeSession()
    res.reason = bad
    return

  for c in changed:
    if not img.procs.hasKey(c):
      sess.closeSession()
      res.reason = "the rebuilt image has no proc called " & c
      return

  for c in changed:
    let err = redirect(d, c, img.procs[c])
    if err.len > 0:
      sess.closeSession()
      res.reason = err
      return

  sess.closeSession()
  inc d.generation
  res.outcome = swSwapped
  res.generation = d.generation
  res.reason = ""
