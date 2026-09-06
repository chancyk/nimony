#       Nif library
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The **artifact store**: a VFS adapter that keeps build artifacts resident in
## the process that produced or read them, so the next access does not go back
## to the filesystem. It is installed with `installArtifactStore` and works the
## way `vfs.nim` says an adapter should: it captures the seven relays that were
## in place and puts wrappers in front of them, so the disk backend is still
## what actually touches the filesystem.
##
## Only `installArtifactStore` changes behaviour. `--vfs:disk` — the default —
## installs nothing at all, and every byte of a build is produced by exactly the
## code that produced it before this module existed.
##
## Policies
## --------
##
## ============== ==========================================================
## `spDisk`       the adapter is not installed. Today's behaviour.
## `spMemory`     entries are resident; a *cross-process* path is still
##                written through to disk (which is every path, until a
##                suffix is declared ephemeral -- see below), an *ephemeral*
##                one is not.
## `spMemorySpill` `spMemory` plus: `storeFlush` writes every memory-only
##                entry out, and the budget spills instead of dropping.
## `spVerify`     everything is written through, and every read that the
##                store answers from memory is compared against the bytes on
##                disk. A mismatch is fatal and names the path and the first
##                differing offset. This is the mode that proves a policy bug
##                is a diagnostic rather than a stale build.
## ============== ==========================================================
##
## Write-through: what is on disk no matter the policy
## ---------------------------------------------------
##
## A store lives in ONE process. Anything a *different* process reads must
## therefore be on disk when that process starts, and today the pipeline is
## process-shaped end to end: nifler writes `.p.nif` and nimsem reads it,
## nimsem writes `.s.nif`/`.s.idx.nif` and hexer and the next nimsem read them,
## `dceEmit` writes `.c.nif` and lengc reads it, lengc writes `.c` and the C
## compiler reads it, and nifmake decides staleness from the mtimes of all of
## them from a fourth process again.
##
## So `crossProcessSuffixes` below — the single place to read for "what is
## always on disk" — currently covers every artifact the build graph names:
##
## ==================== ===================================================
## `.p.nif` `.p.deps.nif` nifler -> nimsem, and the CTFE sub-compile's input
## `.s.nif` `.s.idx.nif` `.s.deps.nif`  nimsem -> nimsem/hexer/deps
## `.sc.nif` `.sc.idx.nif` `.sc.deps.nif` `.pc.nif` `.pc.deps.nif`  the doc-mode twins of those
## `.x.nif` `.dce.nif` `.live.nif` `.c.nif` `.oc.nif`  hexer -> dce -> shoggoth -> lengc
## `.out.nif` `.out.nif.reads`  the CTFE sub-program binary -> nimsem's memo
## `.build.nif` and its `.final`/`.final1`/`.final2`/`.doc`/`.exec` variants  nimony -> nifmake
## `.cfg.nif` `.types.nif` `.asm.nif` `.in.nif` `.linkmanifest.nif`  tool -> tool
## `.c` `.h` `.o` `.ll` `.s` `.a` and executables  lengc/cc/link -> cc/link/exec
## anything under `ocache/`  a *later run's* deps.nim reads it (P0b)
## anything under `ledger/`  the cost ledger, read by the next run (A1a)
## ==================== ===================================================
##
## That the list is "everything" is the finding, not an oversight: a store per
## process buys a read cache and a write coalescer, and nothing more, until
## phases share a process.
##
## Which is why `classifyPath` does not consult that table to decide. It
## answers `pcCrossProcess` by DEFAULT and consults an exception list —
## `addEphemeralSuffix`, empty today — to say otherwise. Getting the default
## the other way round would make a suffix nobody remembered to list into a
## silently stale build, the "high, silent" risk of JIT.md 10; this way it
## costs a write nobody needed. A2b and A2c grow the exception list as the
## phases behind those suffixes move into one process.
##
## A written-through entry can be rewritten by somebody else — a spawned
## `nimony s`, a plugin, a concurrent build — so the store records the disk
## mtime it wrote and drops the entry when the real one has moved. That check
## is a `stat`, which is the syscall `vfsExists`/`vfsMtime` were going to make
## anyway.
##
## Paths intentionally outside the store
## -------------------------------------
##
## The relays are for *file content*. These stay direct OS calls, and the
## adoption pass deliberately left them alone:
##
## - directory operations: `createDir`, `dirExists`, `removeDir`, `walkDir`,
##   `walkFiles`, `getCurrentDir`, `setCurrentDir`. There is no relay for a
##   directory and a store does not model one.
## - `getAppFilename`, `findExe`, `paramStr` and the `.args` files
##   (`argsfinder.nim`): the toolchain's own configuration, read once before
##   any store exists, and identical for every process in the build.
## - user source files (`.nim`, `.cfg`, `.md` read by `slurp`): inputs, never
##   products. Reading them through the store would make the store's budget
##   answer for the size of the project.
## - `moveFile`/`copyFile` of an *executable* into place and the plugin
##   executables: `vfs.vfsMoveInto` already owns that, precisely because the
##   file may be running.
## - `std/tempfiles` scratch directories and the `_d`/`_v` plugin build
##   scratch: removed wholesale by `vfsRemoveTree`, never read as content.
## - stdout/stderr and the tools' own diagnostics.
##
## Representations
## ---------------
##
## `EntryRepr` admits more than the text bytes an entry holds today, because
## A2 wants the same table to hold a `bif` blob (which `foreignmodules.nim`
## already loads zero-copy) and a resident `TokenBuf` (no serialize/reparse at
## all). Only `erText` is produced in A1b; the other two are declared so the
## entry type does not have to change under them.
##
## Invariants
## ----------
##
## - **An entry's bytes are replaced, never mutated.** This is PR #2396's
##   "never truncate a file a reader has mmap'd", carried into memory: a
##   `VfsBlob` over an entry pins that entry's payload, a write installs a
##   *new* payload, and the old bytes stay readable until the last blob over
##   them is closed. (A spill updates the payload's bookkeeping in place —
##   where its disk copy is and when — which no reader can observe.)
## - **Generations live in the mtime space.** A memory-only entry answers
##   `vfsMtime` with the `vfsNow()` value stamped at write time, strictly
##   increasing, so `nifmake.needsRebuild` needs no change.
## - **A written-through entry revalidates.** Its recorded disk mtime is
##   compared against the real one before the store answers from memory, so a
##   child process that rewrote the path underneath us invalidates the entry
##   instead of serving stale bytes. That is one `stat` — the same syscall the
##   caller would have made anyway for `vfsExists`/`vfsMtime`.

when defined(nimony):
  # `vfs.nim` does the same: the relay proc fields, the pin slots and the raw
  # `pointer` a blob carries are all nilable by construction.
  {.feature: "lenientnils".}

import std / [tables, strutils, os, syncio]
when defined(nimony):
  # Nimony's `os` does not re-export these; `vfs.nim` splits the same way.
  import std / [envvars, dirs, paths]
import vfs

const
  DefaultBudgetMB* = 512
    ## `--vfs-budget:<MB>`. JIT.md 5.1: above it the store spills the largest
    ## entries whose policy allows it. A1d replaces "largest" with the ledger's
    ## "cheapest to reload".

type
  StorePolicy* = enum
    spDisk,        ## no adapter; bit-identical to a build without this module
    spMemory,      ## resident; ephemeral paths never reach the disk
    spMemorySpill, ## `spMemory` + flush at `storeFlush` and under budget
    spVerify       ## write through everything and compare every memory read

  PathClass* = enum
    pcCrossProcess, ## another process reads this path: always write through
    pcEphemeral     ## produced and consumed inside this process

  EntryRepr* = enum
    erText,   ## the bytes exactly as they would be on disk. All of A1b.
    erBif,    ## TODO A2: binary NIF with its embedded index, loaded zero-copy
    erTokens  ## TODO A2: a resident `TokenBuf`; no serialize and no reparse

  Payload = ref object
    ## The immutable content of one entry. A `VfsBlob` handed out over it holds
    ## a reference, so replacing the entry cannot free bytes a reader holds.
    bytes: string
    repr: EntryRepr
    generation: int64  ## `vfsNow()` at write time; the memory mtime
    diskMtime: int64   ## the mtime of the written-through copy, 0 if none
    onDisk: bool

  StoreStats* = object
    entries*: int
    residentBytes*: int
    pinnedBytes*: int      ## bytes held only by live blobs after a replace
    reads*, readHits*: int
    writes*, writeThroughs*: int
    mmaps*, mmapHits*: int
    spills*, evictions*: int
    verifyChecks*, verifyMismatches*: int

  ArtifactStore* = object
    ## One per process. It has to be a module-level `var` (below) because the
    ## relays it installs are `nimcall` procs with no context parameter — that
    ## is the shape `vfs.nim` defines. Everything else is threaded through this
    ## object explicitly.
    installed*: bool
    policy*: StorePolicy
    budgetBytes*: int
    lastGeneration: int64
    entries: Table[string, Payload]
    pinned: seq[Payload]   ## one slot per live blob; the slot is the pin
    freeSlots: seq[int]
    stats*: StoreStats
    prevOpenMmap: proc (path: string): VfsBlob {.nimcall.}
    prevRead: proc (path: string): string {.nimcall.}
    prevWrite: proc (path, content: string) {.nimcall.}
    prevExists: proc (path: string): bool {.nimcall.}
    prevMtime: proc (path: string): int64 {.nimcall.}
    prevNow: proc (): int64 {.nimcall.}
    prevRemove: proc (path: string) {.nimcall.}
    ephemeral: seq[string]
      ## Suffixes that are produced and consumed inside one process, so the
      ## policy — not the pipeline — decides whether they reach the disk.
      ## Empty today; A2b and A2c fill it as phases move in-process.

var store: ArtifactStore

# --- the suffix table -----------------------------------------------------

const
  crossProcessSuffixes* = [
    # nifler -> nimsem
    ".p.nif", ".p.deps.nif", ".pc.nif", ".pc.deps.nif", ".cfg.nif",
    # nimsem -> nimsem, hexer, deps
    ".s.nif", ".s.idx.nif", ".s.deps.nif",
    ".sc.nif", ".sc.idx.nif", ".sc.deps.nif",
    # hexer -> dce -> shoggoth -> lengc
    ".x.nif", ".dce.nif", ".live.nif", ".c.nif", ".oc.nif", ".types.nif",
    # the CTFE sub-program's result and P0a's read log
    ".out.nif", ".out.nif.reads",
    # nimony -> nifmake
    ".build.nif",
    # the native backend and the linker
    ".asm.nif", ".in.nif", ".linkmanifest.nif",
    # consumed by tools that are not ours at all
    ".c", ".cpp", ".h", ".o", ".obj", ".ll", ".s", ".a", ".lib", ".dylib",
    ".so", ".dll", ".exe", ".wasm"
  ]
    ## The single place to read for "what is always on disk". See the header.
    ## `.build.nif` covers `.final.build.nif`, `.final1.build.nif`,
    ## `.final2.build.nif`, `.doc.build.nif` and `.exec.build.nif` because they
    ## all end in it.

  crossProcessDirs* = ["ocache", "ledger"]
    ## Directory names under a nimcache whose whole contents outlive the
    ## process: P0b's content-addressed object cache and A1a's cost ledger are
    ## both read by the *next* run.

proc classifyPath*(path: string): PathClass =
  ## Which side of the write-through line `path` falls on. Exposed because the
  ## unit tests assert on the table directly, and because A2b's scheduler wants
  ## the same answer when it decides what to spill before a spawn.
  ##
  ## The default is `pcCrossProcess` and the *exception* list is what shrinks
  ## it. That direction is deliberate: forgetting to list a suffix costs a
  ## write that was not needed, while the other direction costs a silently
  ## stale build — the "high, silent" risk in JIT.md 10. `crossProcessSuffixes`
  ## above is therefore documentation of what the pipeline produces, not the
  ## thing that decides.
  var declared = false
  for e in store.ephemeral:
    if path.endsWith(e): declared = true; break
  if not declared: return pcCrossProcess
  # A suffix the pipeline is documented to hand to another process outranks
  # the declaration: this is what keeps `crossProcessSuffixes` load-bearing
  # rather than a comment that drifts, and it is the guard rail A2b writes
  # against when it starts moving suffixes off the disk.
  for suffix in crossProcessSuffixes:
    if path.endsWith(suffix): return pcCrossProcess
  for d in crossProcessDirs:
    if path.startsWith(d & "/") or path.contains("/" & d & "/"): return pcCrossProcess
    when DirSep != '/':
      if path.startsWith(d & DirSep) or path.contains(DirSep & d & DirSep):
        return pcCrossProcess
  result = pcEphemeral

# --- policy ---------------------------------------------------------------

proc parseStorePolicy*(s: string; policy: var StorePolicy): bool =
  ## `--vfs:<policy>`. Returns false for an unknown name so the caller can
  ## produce its own diagnostic naming the tool.
  result = true
  case s.normalize
  of "disk": policy = spDisk
  of "memory", "mem": policy = spMemory
  of "memory+spill", "memoryspill", "mem+spill": policy = spMemorySpill
  of "verify": policy = spVerify
  else: result = false

proc `$`*(p: StorePolicy): string =
  case p
  of spDisk: "disk"
  of spMemory: "memory"
  of spMemorySpill: "memory+spill"
  of spVerify: "verify"

proc writesThrough(policy: StorePolicy; cls: PathClass): bool {.inline.} =
  ## Verify mode needs the disk copy of everything to have something to
  ## compare against; otherwise only the cross-process half is written.
  policy == spVerify or cls == pcCrossProcess

# --- pinning --------------------------------------------------------------
#
# A pin is a slot in `store.pinned` holding a reference to the payload. The
# blob's cookie is the slot index + 1. Closing the blob clears the slot; the
# payload dies when neither the entries table nor any slot names it.

proc acquirePin(p: Payload): int =
  if store.freeSlots.len > 0:
    result = store.freeSlots.pop()
    store.pinned[result] = p
  else:
    result = store.pinned.len
    store.pinned.add p
  store.stats.pinnedBytes += p.bytes.len

proc releasePin(b: var VfsBlob) {.nimcall.} =
  let idx = cast[int](b.cookie) - 1
  if idx >= 0 and idx < store.pinned.len and store.pinned[idx] != nil:
    store.stats.pinnedBytes -= store.pinned[idx].bytes.len
    store.pinned[idx] = nil
    store.freeSlots.add idx

when defined(nimony):
  proc bytesPtr(s: string): pointer = nil
    ## Nimony rejects `addr s[0]`, so a nimony-built compiler cannot hand out
    ## a blob over a resident entry and `storeOpenMmap` falls through to the
    ## disk backend instead. Every entry is written through today, so this
    ## costs a cache hit and can never cost a wrong answer. (`hastur boot`
    ## compiles nimony, nimsem and hexer with nimony itself; the store is
    ## still installed there, it just does not serve mmaps.)
else:
  proc bytesPtr(s: string): pointer =
    if s.len > 0: cast[pointer](unsafeAddr s[0]) else: nil

proc blobOver(p: Payload): VfsBlob =
  let idx = acquirePin(p)
  result = initBlob(bytesPtr(p.bytes), p.bytes.len, cast[pointer](idx + 1), releasePin)

# --- entry lookup ---------------------------------------------------------

proc entryOf(path: string): Payload =
  ## The one place the entry table is read. `Table.[]` is `.raises` under
  ## nimony, so the lookup is wrapped once here rather than guarded at each of
  ## the seven wrappers; `nil` is "not resident".
  when defined(nimony):
    try: result = store.entries[path]
    except: result = nil
  else:
    result = store.entries.getOrDefault(path, nil)

proc setEnvVar(key, value: string) =
  when defined(nimony):
    try: putEnv(key, value)
    except: discard
  else:
    putEnv(key, value)

proc ensureDir(dir: string) =
  when defined(nimony):
    try: createDir(path(dir))
    except: discard
  else:
    createDir(dir)

# --- generations ----------------------------------------------------------

proc nextGeneration(): int64 =
  ## In `vfsNow`'s nanosecond space and strictly increasing, so two writes
  ## inside one clock tick still order, and so a memory entry can never look
  ## older than an input written a moment earlier.
  result = store.prevNow()
  if result <= store.lastGeneration: result = store.lastGeneration + 1
  store.lastGeneration = result

# --- validity -------------------------------------------------------------

proc isCurrent(path: string; p: Payload): bool =
  ## A memory-only entry is always current: nobody else can write it. A
  ## written-through one is current while the disk copy is the one we wrote —
  ## a spawned child that rewrote the path invalidates us here.
  ##
  ## Verify mode leans on this too: an entry whose disk mtime moved was
  ## legitimately rewritten by somebody else and is simply dropped, so the byte
  ## comparison that follows only ever fires on the case it is looking for —
  ## the same file, the same mtime, different bytes.
  if not p.onDisk: return true
  result = store.prevMtime(path) == p.diskMtime

var storeFatalRelay*: proc (msg: string) {.nimcall.} =
  proc (msg: string) = quit msg
  ## How a verify mismatch is reported. A relay rather than a bare `quit` so
  ## `tests/vfs` can assert on the diagnostic instead of dying with it; the
  ## default is the fatal diagnostic JIT_IMPL.md asks for.

proc firstDifference(a, b: string): int =
  let n = min(a.len, b.len)
  var i = 0
  while i < n:
    if a[i] != b[i]: return i
    inc i
  result = if a.len == b.len: -1 else: n

proc verifyAgainstDisk(path: string; p: Payload) =
  inc store.stats.verifyChecks
  let onDisk = store.prevRead(path)
  let at = firstDifference(p.bytes, onDisk)
  if at >= 0:
    inc store.stats.verifyMismatches
    storeFatalRelay "vfs:verify: artifact store disagrees with the disk copy of " & path &
      "\n  first differing offset: " & $at &
      "\n  in memory: " & $p.bytes.len & " bytes, on disk: " & $onDisk.len & " bytes"

# --- budget ---------------------------------------------------------------

proc spillEntry(path: string; p: Payload) =
  ## Give a memory-only entry a disk copy. After this the bytes may be dropped
  ## from memory without losing them.
  if p.onDisk: return
  store.prevWrite(path, p.bytes)
  p.diskMtime = store.prevMtime(path)
  p.onDisk = true
  inc store.stats.spills

proc dropLargest(): bool =
  ## Evict one entry. Two ranks, then size within a rank: an entry that is
  ## already on the disk costs nothing to shed, while a memory-only one has to
  ## be written out first, so the free ones go first however large the others
  ## are. Returns false when there is nothing left to evict, which is how the
  ## budget stops being enforced rather than becoming a failure.
  ##
  ## Size is the whole ranking here. A1d replaces it with the ledger's
  ## "cheapest to reload": never spill what costs less to recompute.
  var victim = ""
  var victimSize = -1
  var victimFree = false
  for path, p in store.entries:
    # Under `spMemory` a memory-only entry stays put: dropping it would lose
    # the only copy, and writing it out is what `memory+spill` is named after.
    if not p.onDisk and store.policy == spMemory: continue
    if victimSize < 0 or (p.onDisk and not victimFree) or
       (p.onDisk == victimFree and p.bytes.len > victimSize):
      victim = path
      victimSize = p.bytes.len
      victimFree = p.onDisk
  if victimSize < 0: return false
  let p = entryOf(victim)
  if p == nil: return false
  spillEntry(victim, p)
  store.stats.residentBytes -= p.bytes.len
  store.entries.del victim
  dec store.stats.entries
  inc store.stats.evictions
  result = true

proc enforceBudget() =
  while store.stats.residentBytes > store.budgetBytes:
    if not dropLargest(): break

# --- the entry table ------------------------------------------------------

proc putEntry(path, content: string; onDisk: bool; diskMtime: int64) =
  ## Install a NEW payload. The old one, if any, is left to whatever blobs
  ## still hold it.
  let old = entryOf(path)
  if old != nil:
    store.stats.residentBytes -= old.bytes.len
    dec store.stats.entries
  let p = Payload(bytes: content, repr: erText, generation: nextGeneration(),
                  diskMtime: diskMtime, onDisk: onDisk)
  store.entries[path] = p
  inc store.stats.entries
  store.stats.residentBytes += content.len
  enforceBudget()

# --- the seven wrappers ---------------------------------------------------

proc storeWrite(path, content: string) {.nimcall.} =
  inc store.stats.writes
  let cls = classifyPath(path)
  var onDisk = false
  var diskMtime = 0'i64
  if writesThrough(store.policy, cls):
    store.prevWrite(path, content)
    diskMtime = store.prevMtime(path)
    onDisk = true
    inc store.stats.writeThroughs
  putEntry(path, content, onDisk, diskMtime)

proc storeRead(path: string): string {.nimcall.} =
  inc store.stats.reads
  let p = entryOf(path)
  if p != nil:
    if isCurrent(path, p):
      if store.policy == spVerify and p.onDisk:
        verifyAgainstDisk(path, p)
      inc store.stats.readHits
      return p.bytes
  result = store.prevRead(path)
  # Admit it. It came from disk, so it is on disk, and evicting it later is
  # free. `classifyPath` still decides whether a later write goes through.
  putEntry(path, result, true, store.prevMtime(path))

proc storeOpenMmap(path: string): VfsBlob {.nimcall.} =
  inc store.stats.mmaps
  let p = entryOf(path)
  if p != nil:
    if isCurrent(path, p) and bytesPtr(p.bytes) != nil:
      if store.policy == spVerify and p.onDisk:
        verifyAgainstDisk(path, p)
      inc store.stats.mmapHits
      return blobOver(p)
  # Not resident: let the disk backend map it. Mapping is already cheap
  # (JIT.md 3.3: ~0.1 ms per MB) and copying the bytes into the store to hand
  # back a pointer into them would cost more than it saves.
  result = store.prevOpenMmap(path)

proc storeExists(path: string): bool {.nimcall.} =
  let p = entryOf(path)
  if p != nil and not p.onDisk: return true
  result = store.prevExists(path)

proc storeMtime(path: string): int64 {.nimcall.} =
  let p = entryOf(path)
  if p != nil and not p.onDisk: return p.generation
  result = store.prevMtime(path)

proc storeNow(): int64 {.nimcall.} = store.prevNow()

proc storeRemove(path: string) {.nimcall.} =
  let p = entryOf(path)
  if p != nil:
    store.stats.residentBytes -= p.bytes.len
    dec store.stats.entries
  store.entries.del path
  store.prevRemove(path)

# --- installation ---------------------------------------------------------

proc addEphemeralSuffix*(suffix: string) =
  ## Declare that nothing outside this process reads a file ending in
  ## `suffix`, so the policy decides whether it is written at all.
  if suffix.len > 0 and suffix notin store.ephemeral:
    store.ephemeral.add suffix

proc installArtifactStore*(policy: StorePolicy;
                           budgetBytes = DefaultBudgetMB * 1024 * 1024) =
  ## Capture the seven relays and put the store in front of them. `spDisk`
  ## installs nothing — that is the escape hatch, and it must leave the process
  ## byte-identical to one that never called this.
  if policy == spDisk or store.installed: return
  store.installed = true
  store.policy = policy
  store.budgetBytes = budgetBytes
  store.entries = initTable[string, Payload]()
  store.prevOpenMmap = openMmapRelay
  store.prevRead = readBytesRelay
  store.prevWrite = writeBytesRelay
  store.prevExists = existsRelay
  store.prevMtime = mtimeRelay
  store.prevNow = nowRelay
  store.prevRemove = removeRelay
  openMmapRelay = storeOpenMmap
  readBytesRelay = storeRead
  writeBytesRelay = storeWrite
  existsRelay = storeExists
  mtimeRelay = storeMtime
  nowRelay = storeNow
  removeRelay = storeRemove

proc uninstallArtifactStore*() =
  ## Put the captured relays back and forget every entry. Only the unit tests
  ## need this today (one process, several policies); A2a wants the same reset
  ## between two in-process phases.
  if not store.installed: return
  openMmapRelay = store.prevOpenMmap
  readBytesRelay = store.prevRead
  writeBytesRelay = store.prevWrite
  existsRelay = store.prevExists
  mtimeRelay = store.prevMtime
  nowRelay = store.prevNow
  removeRelay = store.prevRemove
  store = default(ArtifactStore)

# --- the CLI / environment seam -------------------------------------------
#
# `--vfs:<policy>` and `--vfs-budget:<MB>` are parsed by each tool's own option
# loop (nimony and nimsem share `cli.parseCommonOption`). The resolved policy
# is then exported into the environment, which is how it reaches the tools
# nimony does not hand a command line to: nifmake, and through it nifler,
# hexer, lengc and the nested `nimony s` of a CTFE sub-compile.
#
# The environment rather than the `.build.nif` on purpose. Splicing the flag
# into the build graph would make two `--vfs` modes emit different
# `*.build.nif` bytes, and byte-identical artifacts across modes is exactly
# what this phase's gate asserts.

const
  VfsPolicyEnv* = "NIMONY_VFS"
  VfsBudgetEnv* = "NIMONY_VFS_BUDGET"
  VfsStatsEnv* = "NIMONY_VFS_STATS"

type
  StoreRequest = object
    ## What the command line asked for, before the environment is consulted.
    policy: string
    budgetMB: int

var request: StoreRequest

proc requestStorePolicy*(name: string): bool =
  ## `--vfs:<name>`. False means the name is not a policy; the caller produces
  ## the diagnostic, so it can name its own tool.
  var p = spDisk
  result = parseStorePolicy(name, p)
  if result: request.policy = $p

proc parseBudgetMB*(text: string): int =
  ## `--vfs-budget:<MB>`, parsed once for every tool that accepts the flag.
  ## Anything that is not a positive number of megabytes comes back as -1 and
  ## the caller produces its own diagnostic.
  result = -1
  when defined(nimony):
    try: result = parseInt(text)
    except: result = -1
  else:
    try: result = parseInt(text)
    except ValueError: result = -1
  if result <= 0: result = -1

proc requestStoreBudgetMB*(mb: int) =
  ## `--vfs-budget:<MB>`. Zero or less leaves the default in place.
  if mb > 0: request.budgetMB = mb

proc applyRequestedStore*() =
  ## Install what the flag, or failing that the environment, asked for, and
  ## export the answer so every child process inherits it. Called once by each
  ## tool after its options are parsed and before it does any work.
  var name = request.policy
  if name.len == 0: name = getEnv(VfsPolicyEnv)
  if name.len == 0: return
  var p = spDisk
  if not parseStorePolicy(name, p): return
  var mb = request.budgetMB
  if mb <= 0:
    let fromEnv = getEnv(VfsBudgetEnv)
    if fromEnv.len > 0: mb = parseBudgetMB(fromEnv)
  if mb <= 0: mb = DefaultBudgetMB
  setEnvVar(VfsPolicyEnv, $p)
  setEnvVar(VfsBudgetEnv, $mb)
  installArtifactStore(p, mb * 1024 * 1024)

proc storeInstalled*(): bool = store.installed
proc storePolicy*(): StorePolicy = store.policy
proc storeStats*(): StoreStats = store.stats

# --- reporting ------------------------------------------------------------

proc storeStatsLine*(): string =
  ## One line for `--stats` (A1d prints it beside the phase table).
  let s = store.stats
  result = "[store] policy=" & $store.policy &
    " entries=" & $s.entries &
    " resident=" & $(s.residentBytes div 1024) & "KB" &
    " pinned=" & $(s.pinnedBytes div 1024) & "KB" &
    " reads=" & $s.reads & " hits=" & $s.readHits &
    " mmaps=" & $s.mmaps & " mmapHits=" & $s.mmapHits &
    " writes=" & $s.writes & " through=" & $s.writeThroughs &
    " spills=" & $s.spills & " evictions=" & $s.evictions &
    " verify=" & $s.verifyChecks & " mismatches=" & $s.verifyMismatches

# --- spilling -------------------------------------------------------------

proc spillAll*(paths: openArray[string]) =
  ## Give these paths a disk copy. A2b calls it on a node's inputs before
  ## spawning the process that will read them.
  if not store.installed: return
  for path in paths:
    let p = entryOf(path)
    if p != nil: spillEntry(path, p)

proc spillAll*() =
  ## Every memory-only entry. This is `storeFlush` without the policy check.
  if not store.installed: return
  for path, p in store.entries:
    spillEntry(path, p)

proc storeFlush*() =
  ## Called at the end of a tool's `main`. Under `memory+spill` it is what
  ## makes the mode safe for a process whose successor reads what it wrote;
  ## under plain `memory` it deliberately does nothing, which is why that mode
  ## is only useful once the phases share a process (JIT_IMPL.md A2c).
  if not store.installed: return
  if store.policy == spMemorySpill:
    spillAll()
  # `NIMONY_VFS_STATS=1` makes every process of a build print its own store
  # line on stderr. It is how a test proves the store was engaged at all --
  # `verify=0` would mean the adapter never answered a read from memory and
  # the mode proved nothing.
  if getEnv(VfsStatsEnv).len > 0:
    stderr.writeLine storeStatsLine()

proc spillTo*(dir: string) =
  ## Write a copy of every resident entry into `dir`, named by the artifact's
  ## own filename. For `--dump`-style inspection of a memory-only build: the
  ## point is to be able to look at every artifact that exists, which is the
  ## debugging story JIT.md 5.1 asks the store to keep. Flat on purpose --
  ## two entries whose basenames collide (a module's `.c.nif` at the cache
  ## root and its twin in a backend directory) land on one file, which is the
  ## right trade for a dump you read by name.
  if not store.installed: return
  ensureDir(dir)
  for path, p in store.entries:
    store.prevWrite(dir / extractFilename(path), p.bytes)

