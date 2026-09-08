#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Reading the guest's stack from the loader, at a safepoint — JIT.md 7.4's
## *"live frames are checked with nifasm's 16-byte-per-proc trace table
## (fixed-frame CFA, no CFI interpreter): a swap is deferred while a frame of
## the replaced proc is live"*.
##
## Why this is the loader's code and not the guest's
## -------------------------------------------------
##
## `notes/b4.md` §1a argues it from the table's own definition: `cfaOff` is one
## number per proc and is valid only past that proc's prologue
## (`nifasm/image/tracetable.nim`), so the walk needs a SYNCHRONOUS seed — a
## frame the program itself called into. It gets one for free here: the guest
## calls `nimony_dev_poll` (`lib/std/devreload.nim`), the loader's intercept
## answers it, and that intercept runs **on the guest's thread, in a frame the
## guest called**. The loader shares the guest's address space, so from there
## the walk is ordinary pointer arithmetic in host Nim — no intrinsic, no
## guest-side walker, nothing from arkham.
##
## How a frame is stepped
## ----------------------
##
## By the frame-record chain, not by `cfaOff`, and the two coincide here. arkham
## keeps x29 pointing at a valid `{saved fp, saved lr}` pair on Darwin outright
## — *"its ABI requires x29 to address a valid frame record"*
## (`arkham/risc/frame.nim:302-303`) — and lr is deliberately kept at `CFA - 8`
## (`frame.nim:290-296`), which for a frame whose head pair is fp/lr is
## precisely `fp + 8`. So `[fp]` is the caller's record and `[fp+8]` is the
## return address into the caller, and stepping the chain visits exactly the
## slots the table's `slot += cfaOff` rule would.
##
## The table is still the mechanism, and it is the half that cannot be
## replaced: a return address is a number, and only the table says which PROC
## contains it. `MemImage.procs` gives every proc's entry but not its EXTENT,
## and an extent is what "is a frame of this proc live" needs.
##
## Where this is not portable, and why that is fine for B4: the frame-record
## chain is a Darwin guarantee. `frame.nim` drops x29 on linux/arm64 when it
## can, and x86-64 is the target `--dev-single-thread` does not lower
## `&threadvar` for at all (JIT_IMPL.md B5). A port steps by `cfaOff` instead,
## which is the same table and the same walk with a different seed — see
## `notes/b4.md`.

import std / [strutils, algorithm]

const
  TraceMagic = 0x4352544E'u32   ## 'N','T','R','C' — `nifasm/image/tracetable.nim`
  TraceHeaderSize = 16
  TraceEntrySize = 16
  MaxFrames* = 256
    ## A bound on the walk. A corrupt chain must produce a short answer rather
    ## than an endless one, and a safepoint is not the place to hang.
  MaxStackSpan = 64'u * 1024 * 1024
    ## How far up the stack the walk may travel before it calls the chain
    ## broken. The guest thread's stack is 8 MB (`hostrun.GuestStackBytes`), so
    ## anything past this is not a stack any more.

type
  TraceTable* = object
    ## nifasm's per-proc metadata blob, as the loader sees it: an address in the
    ## guest's arena and the row count out of its header. `base == 0` means the
    ## image carries no table, which is a REFUSAL rather than an empty answer —
    ## a walk that cannot name a proc cannot decide liveness either.
    base*: uint
    count*: int

  GuestFrames* = object
    ## The return addresses found on the guest's stack, innermost first, and
    ## whether the walk finished or ran into its own bound. `truncated` matters:
    ## a truncated walk has NOT proved that a proc is absent, so it must never
    ## be read as "safe to swap".
    pcs*: seq[uint]
    truncated*: bool

proc readU32(base: uint; off: int): uint32 {.inline.} =
  cast[ptr uint32](base + uint(off))[]

proc readWord(at: uint): uint {.inline.} =
  cast[ptr uint](at)[]

proc openTraceTable*(at: uint): TraceTable =
  ## Read the header. Every field of the table is self-relative, so nothing here
  ## depends on where the arena was mapped.
  result = TraceTable(base: 0, count: 0)
  if at == 0: return
  if readU32(at, 0) != TraceMagic: return
  if readU32(at, 12) != uint32(TraceEntrySize): return
  result = TraceTable(base: at, count: int(readU32(at, 8)))

proc signed32(v: uint32): int {.inline.} =
  ## Two's-complement widening by hand. A stored code offset is a signed 32-bit
  ## distance from the table, and zero-extending instead of sign-extending turns
  ## every proc that precedes the table — which is all of them — into an address
  ## four gigabytes away.
  result = int(v)
  if result >= 2147483648: result = result - 4294967296

proc rowStart*(t: TraceTable; i: int): uint {.inline.} =
  cast[uint](cast[int](t.base) + signed32(readU32(t.base, TraceHeaderSize + i * TraceEntrySize)))

proc rowLen*(t: TraceTable; i: int): uint {.inline.} =
  uint(readU32(t.base, TraceHeaderSize + i * TraceEntrySize + 4))

proc rowName*(t: TraceTable; i: int): string =
  ## The proc's nifasm symbol, copied out of the table's name blob. Verbatim:
  ## the classifier matches it against the names in `MemImage.procs`, which are
  ## the same spelling, so nothing may be prettified on the way out.
  let at = t.base + uint(readU32(t.base, TraceHeaderSize + i * TraceEntrySize + 12))
  let s = cast[ptr UncheckedArray[char]](at)
  result = ""
  var k = 0
  while s[k] != '\0' and k < 512:
    result.add s[k]
    inc k

proc findProc*(t: TraceTable; pc: uint): int =
  ## The row whose code range contains `pc`, or -1. Rows are sorted by address
  ## (`tracetable.collectTraceProcs` sorts them), so this is a binary search.
  result = -1
  var lo = 0
  var hi = t.count - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let start = rowStart(t, mid)
    if pc < start: hi = mid - 1
    elif pc >= start + rowLen(t, mid): lo = mid + 1
    else: return mid

proc frameAddress(level: cint): pointer
  {.importc: "__builtin_frame_address", nodecl.}
  ## The current function's frame-record pointer. `0` is the only level ever
  ## passed and the only one the builtin promises anything about.

proc walkFromHere*(codeLo, codeHi: uint; dest: var GuestFrames) =
  ## Collect the return addresses on this thread's stack that lie in
  ## `[codeLo, codeHi)`, innermost first.
  ##
  ## Called from the safepoint intercept, so frame 0 is the intercept's own —
  ## host code, outside the range, and dropped by the range test rather than by
  ## a special case. Everything above it up to the guest's `main` is the guest;
  ## above THAT is `hostrun.guestBody` and the thread start, host code again and
  ## dropped the same way.
  ##
  ## Three bounds, and each has a failure it exists for: the frame cap stops a
  ## cycle, the monotonicity test stops a chain that points back down the stack,
  ## and the span test stops one that points at memory that is not a stack.
  dest.pcs = @[]
  dest.truncated = false
  var fp = cast[uint](frameAddress(0))
  if fp == 0: return
  let origin = fp
  var frames = 0
  while frames < MaxFrames:
    let nextFp = readWord(fp)
    let pc = readWord(fp + 8)
    if pc >= codeLo and pc < codeHi:
      dest.pcs.add pc
    if nextFp <= fp: return                 # not going up any more: the top
    if nextFp - origin > MaxStackSpan: return
    fp = nextFp
    inc frames
  dest.truncated = true

proc liveIn*(t: TraceTable; frames: GuestFrames; lo, hi: uint): bool =
  ## Is any collected return address inside `[lo, hi)`? The caller passes one
  ## proc's code range, read off the table.
  for pc in frames.pcs:
    if pc >= lo and pc < hi: return true
  result = false

proc liveProcs*(t: TraceTable; frames: GuestFrames; names: seq[string]): seq[string] =
  ## Which of `names` has a live frame. Returns the NAMES rather than a bool so
  ## the deferral can say which proc is holding the swap up — a reload that is
  ## deferred without saying why is the same failure this phase exists to avoid
  ## for a restart.
  result = @[]
  for pc in frames.pcs:
    let idx = findProc(t, pc)
    if idx < 0: continue
    let n = rowName(t, idx)
    for want in names:
      if n == want and n notin result:
        result.add n
  # Deterministic order, so a diagnostic does not change between two runs that
  # found the same thing.
  result.sort()

proc describe*(t: TraceTable; frames: GuestFrames): string =
  ## The guest's stack as one line, for `--verbose`. Innermost first.
  result = ""
  for pc in frames.pcs:
    let idx = findProc(t, pc)
    if result.len > 0: result.add " < "
    result.add (if idx < 0: "?" else: rowName(t, idx))
  if frames.truncated: result.add " < ..."
