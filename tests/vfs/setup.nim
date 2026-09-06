## Custom runner: unit tests over `src/lib/artifactstore.nim`.
##
## The store sits behind the VFS relays, so everything here is written through
## the ordinary `vfs*` wrappers — that is the surface the rest of the compiler
## uses, and testing it any other way would prove something about the store
## that the compiler cannot observe.
##
## What each case is for:
##
## - **put/get, replace, generation**: the store must answer a read with what
##   was last written, and a memory-only entry must answer `vfsMtime` with a
##   strictly increasing stamp in `vfsNow`'s nanosecond space. `nifmake`'s
##   whole staleness model is `<`/`>=` on that number, so two writes inside
##   one clock tick still have to order.
## - **write-through vs ephemeral**: the classification table decides what
##   reaches the disk. The default has to be "written through" — see
##   `classifyPath`'s comment for why that direction and not the other.
## - **blob lifetime**: PR #2396's invariant. A `VfsBlob` handed out over an
##   entry must keep reading the bytes it was opened over even after the entry
##   is replaced, and the bytes must go away when the last blob closes.
## - **budget**: over the budget the store sheds entries; a shed entry must
##   still read back correctly, because shedding is a cache decision and never
##   a data decision.
## - **verify**: the mode exists to turn a policy bug into a diagnostic. The
##   case plants a disk copy that differs while keeping the mtime — an mtime
##   that moved means somebody legitimately rewrote the file, and the store
##   drops the entry instead — and asserts the diagnostic names the path and
##   the first differing offset.

import std / [os, strutils, times]
import "../../src/lib/vfs"
import "../../src/lib/artifactstore"

var failures = 0

proc fail(msg: string) =
  echo "  FAIL: ", msg
  inc failures

proc ok(msg: string) =
  echo "  ok: ", msg

proc check(cond: bool; msg: string) =
  if cond: ok msg else: fail msg

# The store is a per-process singleton (the relays it installs are `nimcall`
# procs with no context parameter), so each case installs it, runs, and puts
# the old relays back.

var scratch = ""

proc caseDir(name: string): string =
  result = scratch / name
  createDir result

# ---- the classification table ---------------------------------------------

proc tableCase() =
  echo "the write-through table"
  installArtifactStore(spMemory)
  check classifyPath("nimcache/foo.s.nif") == pcCrossProcess, ".s.nif is written through"
  check classifyPath("nimcache/foo.s.idx.nif") == pcCrossProcess, ".s.idx.nif is written through"
  check classifyPath("nimcache/foo.out.nif.reads") == pcCrossProcess,
        ".out.nif.reads is written through"
  check classifyPath("nimcache/ocache/abc.o") == pcCrossProcess, "ocache/ is written through"
  check classifyPath("nimcache/anything-at-all") == pcCrossProcess,
        "an unclassified path is written through by default"
  addEphemeralSuffix ".scratch.nif"
  check classifyPath("nimcache/foo.scratch.nif") == pcEphemeral,
        "a declared ephemeral suffix is not"
  check classifyPath("nimcache/foo.s.nif") == pcCrossProcess,
        "declaring one suffix does not move the others"
  uninstallArtifactStore()

# ---- put / get / replace / generation -------------------------------------

proc basicsCase() =
  echo "put, get, replace, generation"
  let dir = caseDir("basics")
  installArtifactStore(spMemory)
  addEphemeralSuffix ".mem.nif"
  let p = dir / "a.mem.nif"

  vfsWrite(p, "one")
  check vfsExists(p), "a memory-only entry exists"
  check vfsRead(p) == "one", "reads back what was written"
  check not fileExists(p), "a memory-only entry never reached the disk"
  let g1 = vfsMtime(p)

  vfsWrite(p, "two")
  check vfsRead(p) == "two", "a replace is what the next read sees"
  let g2 = vfsMtime(p)
  check g2 > g1, "the generation moved: " & $g1 & " -> " & $g2

  # Three writes with no clock tick between them still have to order, which is
  # what `nifmake` needs and what a bare `getTime()` would not give.
  vfsWrite(p, "three")
  vfsWrite(p, "four")
  let g3 = vfsMtime(p)
  check g3 > g2, "back-to-back writes keep the generation strictly increasing"

  let now = vfsNow()
  check g3 <= now + 1_000_000_000'i64 and g3 > 0,
        "the generation lives in vfsNow's nanosecond space"

  vfsRemove(p)
  check not vfsExists(p), "remove drops the entry"
  uninstallArtifactStore()

proc writeThroughCase() =
  echo "write-through"
  let dir = caseDir("through")
  installArtifactStore(spMemory)
  let p = dir / "a.s.nif"
  vfsWrite(p, "semchecked")
  check fileExists(p), "a cross-process entry is on the disk immediately"
  check readFile(p) == "semchecked", "and holds the bytes that were written"
  check vfsMtime(p) == getLastModificationTime(p).toUnix * 1_000_000_000'i64 +
        getLastModificationTime(p).nanosecond,
        "a written-through entry reports the DISK mtime, not its generation"
  uninstallArtifactStore()

# ---- blob lifetime (PR #2396 in memory) -----------------------------------

proc blobCase() =
  echo "a blob pins the bytes it was opened over"
  let dir = caseDir("blob")
  installArtifactStore(spMemory)
  addEphemeralSuffix ".mem.nif"
  let p = dir / "b.mem.nif"

  var original = newStringOfCap(200_000)
  for i in 0 ..< 200_000: original.add 'x'
  vfsWrite(p, original)

  var blob = vfsOpenMmap(p)
  if blob.size != 200_000:
    fail "the store did not answer the mmap (size " & $blob.size & ")"
    uninstallArtifactStore()
    return
  check storeStats().pinnedBytes == 200_000, "the blob is accounted for as pinned"

  # Replace the entry with something much smaller. Against a store that
  # mutated the payload this is the SIGBUS of the on-disk case.
  vfsWrite(p, "short\n")
  check vfsRead(p) == "short\n", "the entry now holds the new bytes"

  var sum = 0
  let data = cast[ptr UncheckedArray[char]](blob.data)
  for i in 0 ..< blob.size: sum = sum + int(data[i])
  check sum == 200_000 * int('x'), "the held blob still reads its original bytes"

  closeBlob blob
  check storeStats().pinnedBytes == 0, "closing the blob releases the pin"
  uninstallArtifactStore()

# ---- spill and budget ------------------------------------------------------

proc spillCase() =
  echo "spill"
  let dir = caseDir("spill")
  installArtifactStore(spMemorySpill)
  addEphemeralSuffix ".mem.nif"
  let a = dir / "a.mem.nif"
  let b = dir / "b.mem.nif"
  vfsWrite(a, "alpha")
  vfsWrite(b, "beta")
  check not fileExists(a) and not fileExists(b), "nothing on the disk yet"

  spillAll([a])
  check fileExists(a) and readFile(a) == "alpha", "spillAll(paths) wrote the named entry"
  check not fileExists(b), "and only the named one"

  storeFlush()
  check fileExists(b) and readFile(b) == "beta", "storeFlush wrote the rest"

  let dump = dir / "dump"
  spillTo(dump)
  check fileExists(dump / "a.mem.nif") and fileExists(dump / "b.mem.nif"),
        "spillTo copied every resident entry"
  uninstallArtifactStore()

proc budgetCase() =
  echo "budget"
  let dir = caseDir("budget")
  # 1 MB of budget against 8 entries of 512 KB: the store has to shed.
  installArtifactStore(spMemorySpill, 1024 * 1024)
  var body = newStringOfCap(512 * 1024)
  for i in 0 ..< 512 * 1024: body.add char(ord('a') + (i mod 26))
  var paths: seq[string] = @[]
  for i in 0 ..< 8:
    let p = dir / ("e" & $i & ".s.nif")
    paths.add p
    vfsWrite(p, body & $i)
  let st = storeStats()
  check st.evictions > 0, "the budget shed entries (" & $st.evictions & ")"
  check st.residentBytes <= 1024 * 1024,
        "resident bytes stayed within the budget (" & $st.residentBytes & ")"
  var allBack = true
  for i, p in paths:
    if vfsRead(p) != body & $i: allBack = false
  check allBack, "every entry still reads back correctly after being shed"
  uninstallArtifactStore()

# ---- verify ----------------------------------------------------------------

var lastFatal = ""

proc recordFatal(msg: string) {.nimcall.} =
  lastFatal = msg

proc verifyCase() =
  echo "verify"
  let dir = caseDir("verify")
  installArtifactStore(spVerify)
  let p = dir / "v.s.nif"
  vfsWrite(p, "aaaaXaaaa")
  check fileExists(p), "verify mode writes everything through"
  check vfsRead(p) == "aaaaXaaaa", "an agreeing read is just a read"
  check storeStats().verifyChecks >= 1, "and it was checked"
  check storeStats().verifyMismatches == 0, "with no mismatch"

  # A disk copy that changed AND moved its mtime is somebody else's legitimate
  # rewrite: the entry is dropped, not reported.
  writeFile(p, "somebody else wrote this")
  check vfsRead(p) == "somebody else wrote this",
        "a rewrite with a moved mtime invalidates the entry instead of firing"
  check storeStats().verifyMismatches == 0, "and is not a mismatch"

  # Same file, same mtime, different bytes: exactly what verify is for.
  # `setLastModificationTime` goes through `utimes` (microseconds) while the
  # mtime the store records is nanoseconds, so the file's stamp is first
  # normalised to a fixed point of that round trip and only then admitted —
  # otherwise restoring it below would read as somebody else's rewrite and the
  # entry would be dropped before the comparison.
  vfsWrite(p, "aaaaXaaaa")
  setLastModificationTime(p, getLastModificationTime(p))
  let stamp = getLastModificationTime(p)
  discard vfsRead(p)
  writeFile(p, "aaaaYaaaa")
  setLastModificationTime(p, stamp)
  storeFatalRelay = recordFatal
  lastFatal = ""
  discard vfsRead(p)
  storeFatalRelay = proc (msg: string) {.nimcall.} = quit msg
  if lastFatal.len == 0:
    fail "a corrupted disk copy went unreported"
  else:
    check lastFatal.contains(p), "the diagnostic names the path"
    check lastFatal.contains("first differing offset: 4"),
          "and the first differing offset: " & lastFatal.splitLines[1]
    check storeStats().verifyMismatches >= 1, "and it is counted"
  uninstallArtifactStore()

# ---- disk mode is not a store ---------------------------------------------

proc diskCase() =
  echo "disk mode installs nothing"
  installArtifactStore(spDisk)
  check not storeInstalled(), "--vfs:disk leaves the relays alone"

# ---- policy names ----------------------------------------------------------

proc policyNamesCase() =
  echo "policy names"
  var p = spDisk
  check parseStorePolicy("disk", p) and p == spDisk, "disk"
  check parseStorePolicy("memory", p) and p == spMemory, "memory"
  check parseStorePolicy("memory+spill", p) and p == spMemorySpill, "memory+spill"
  check parseStorePolicy("verify", p) and p == spVerify, "verify"
  check not parseStorePolicy("nonsense", p), "an unknown name is rejected"
  check $spMemorySpill == "memory+spill", "and round-trips to its spelling"

scratch = getTempDir() / "nimony_vfs_tests"
removeDir scratch
createDir scratch

diskCase()
policyNamesCase()
tableCase()
basicsCase()
writeThroughCase()
blobCase()
spillCase()
budgetCase()
verifyCase()

removeDir scratch

if failures > 0:
  echo "vfs: ", failures, " failure(s)"
  quit 1
echo "vfs: all checks passed"
