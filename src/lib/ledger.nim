#       Nif library
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The cost ledger (JIT.md 5.2).
##
## Every phase of a build reports what it cost: the time to run the phase
## proper (`produce`), to turn the result into bytes (`serialize`), to publish
## it (`write`), to get the input back (`load` + `parse`), the process start
## behind it (`spawn`), and the size of what it produced (`bytes`). Samples are
## aggregated per (phase, module) with an exponentially weighted average and
## survive across runs, so the scheduler can answer "is this cheaper to
## recompute than to reload" and "is this worth a process" from measurements of
## *this* machine rather than from constants.
##
## Storage. One process must never contend with another over a single file:
## `nifmake -j` runs a dozen tools at once. Each tool therefore writes its own
## **fragment**, `<dir>/.ledger/<phase>_<module>.nif`, where `<dir>` is the
## directory that phase writes its artifacts into. `openLedger` folds the
## fragments it finds below the nimcache into the table, so nothing has to be
## merged for the numbers to be readable. `saveLedger` publishes the folded
## table as `<nimcache>/ledger.nif`; fragments are left in place (they, not the
## snapshot, carry the per-key history).
##
## Two directory levels are scanned because the backend phases write into
## `<nimcache>/<main>_c/` rather than into the nimcache itself: `lengc` is
## handed `--nimcache:<backendDir>` and the main module's `hexer` an
## `--outdir:<backendDir>`. Deriving a "real" nimcache from those would mean
## guessing at directory names; folding one level down does not.
##
## Toolhash. A sample is stamped with `toolhash()` of the process that took it.
## `record` starts a fresh average when the stamp changes (a rebuilt tool's
## timings are not a continuation of the old tool's), and `estimate` ignores an
## entry stamped by another tool build. The entry stays on disk until the next
## sample overwrites it.

when defined(nimony):
  import std / [os, dirs, paths, strutils, monotimes]
else:
  import std / [os, strutils, monotimes]

import vfs, nifbuilder, nifreader, toolhash
export toolhash

type
  LedgerKey* = object
    phase*: string   ## "nifler" | "nimsem" | "hexer" | "dceLive" | "dceEmit" |
                     ## "lengc" | "cc" | "link" | ...
    module*: string  ## module suffix, "" for whole-program nodes

  LedgerSample* = object
    produceNs*, serializeNs*, writeNs*, loadNs*, parseNs*, spawnNs*: int64
    bytes*: int64

  LedgerEntry* = object
    key*: LedgerKey
    ewma*: LedgerSample  ## exponentially weighted, alpha 0.3
    samples*: int
    updated*: int64      ## unix ns
    toolhash*: string

  Ledger* = object
    path*: string             ## `<nimcache>/ledger.nif`
    entries*: seq[LedgerEntry]  ## sorted by (phase, module)
    current*: string          ## the toolhash `estimate` accepts
    dirty*: bool

const
  AlphaNum = 3
  AlphaDen = 10
    ## EWMA alpha 0.3, as integer arithmetic: `new = (7*old + 3*x) / 10`.
    ## Nanoseconds are integral to begin with and the rounding is irrelevant at
    ## this scale; keeping floats out means the NIF round trip is exact.
  Ms = 1_000_000'i64
  FragmentDirName = ".ledger"
    ## Dot-prefixed on purpose. Fragments land in the directory their phase
    ## writes into, and for the backend phases that is `<nimcache>/<main>_c/`
    ## -- the directory the linker puts the executable in. A plain `ledger`
    ## would collide with a user program named `ledger.nim`; a name that is not
    ## a legal module name cannot.

# --- small OS helpers, non-raising in both dialects -----------------------

proc ensureDir(dir: string) =
  when defined(nimony):
    try: createDir(path(dir)) except: discard
  else:
    try: createDir(dir) except CatchableError: discard

proc addNifFiles(dir: string; res: var seq[string]) =
  when defined(nimony):
    try:
      for it in walkDir(path(dir)):
        let p = $it.path
        if it.kind == pcFile and p.endsWith(".nif"): res.add p
    except: discard
  else:
    try:
      for kind, p in walkDir(dir):
        if kind == pcFile and p.endsWith(".nif"): res.add p
    except CatchableError: discard

proc addSubdirs(dir: string; res: var seq[string]) =
  when defined(nimony):
    try:
      for it in walkDir(path(dir)):
        if it.kind == pcDir: res.add $it.path
    except: discard
  else:
    try:
      for kind, p in walkDir(dir):
        if kind == pcDir: res.add p
    except CatchableError: discard

proc monoNs(): int64 {.inline.} = getMonoTime().ticks

proc moduleSuffixOf*(path: string): string =
  ## The NIF module suffix a tool derives from an artifact path: the basename
  ## up to its first dot, the same cut `modnames.splitModulePath` makes. Kept
  ## local so that a tool can name its ledger fragment without pulling the
  ## front end's path machinery in.
  var start = 0
  var stop = path.len
  var seenDot = false
  var i = 0
  while i < path.len:
    let c = path[i]
    if c == '/' or c == '\\':
      start = i + 1
      stop = path.len
      seenDot = false
    elif c == '.' and not seenDot:
      stop = i
      seenDot = true
    inc i
  result = ""
  var j = start
  while j < stop:
    result.add path[j]
    inc j

proc phaseForArtifact*(path: string): string =
  ## Which phase produces a file with this suffix, or `""` when nothing in the
  ## pipeline claims it.
  ##
  ## This is the other direction of the key: a tool naming its *own* fragment
  ## knows its phase, while a consumer holding only a path -- the artifact store
  ## deciding whether an entry is cheaper to recompute than to reload (A1d) --
  ## has to read it off the name. The table is the one in `deps.nim`'s file
  ## naming procs, in the order the pipeline produces them.
  ##
  ## An unclaimed suffix answers `""` on purpose, and the caller must read that
  ## as "there is no phase that could recompute this", not as "cost unknown":
  ## the sidecars (`.deps.nif`, `.s.idx.nif`), the build files and anything a
  ## plugin invented have no producing phase in the ledger's sense, so the only
  ## way back to their bytes is to read them.
  if path.endsWith(".p.nif") or path.endsWith(".pc.nif"): result = "nifler"
  elif path.endsWith(".s.nif") or path.endsWith(".sc.nif"): result = "nimsem"
  elif path.endsWith(".x.nif") or path.endsWith(".dce.nif"): result = "hexer"
  elif path.endsWith(".live.nif"): result = "dceLive"
  elif path.endsWith(".c.nif") or path.endsWith(".oc.nif"): result = "dceEmit"
  elif path.endsWith(".c") or path.endsWith(".cpp") or path.endsWith(".ll") or
       path.endsWith(".asm.nif"): result = "lengc"
  elif path.endsWith(".o") or path.endsWith(".obj"): result = "cc"
  else: result = ""

proc artifactKey*(path: string): LedgerKey =
  ## The ledger key of the phase that produced `path`. `phase == ""` means
  ## nothing did; see `phaseForArtifact`.
  let phase = phaseForArtifact(path)
  if phase.len == 0: LedgerKey(phase: "", module: "")
  else: LedgerKey(phase: phase, module: moduleSuffixOf(path))

# --- keys and samples ------------------------------------------------------

proc `<`(a, b: LedgerKey): bool =
  if a.phase != b.phase: a.phase < b.phase else: a.module < b.module

proc `==`*(a, b: LedgerKey): bool =
  a.phase == b.phase and a.module == b.module

proc ewmaStep(old, x: int64): int64 {.inline.} =
  ((AlphaDen - AlphaNum) * old + AlphaNum * x) div AlphaDen

proc blend(old: LedgerSample; x: LedgerSample): LedgerSample =
  result = LedgerSample(
    produceNs: ewmaStep(old.produceNs, x.produceNs),
    serializeNs: ewmaStep(old.serializeNs, x.serializeNs),
    writeNs: ewmaStep(old.writeNs, x.writeNs),
    loadNs: ewmaStep(old.loadNs, x.loadNs),
    parseNs: ewmaStep(old.parseNs, x.parseNs),
    spawnNs: ewmaStep(old.spawnNs, x.spawnNs),
    bytes: ewmaStep(old.bytes, x.bytes))

proc defaultSample*(phase: string): LedgerSample =
  ## The table of JIT.md 3.3, used when nothing has ever been measured. Every
  ## phase carries the ~3 ms of process start it takes to reach it.
  result = LedgerSample(spawnNs: 3 * Ms)
  case phase
  of "nifler": result.produceNs = 3 * Ms
  of "nimsem": result.produceNs = 7 * Ms
  of "hexer": result.produceNs = 7 * Ms
  of "lengc": result.produceNs = 6 * Ms
  of "cc": result.produceNs = 54 * Ms
  of "link": result.produceNs = 33 * Ms
  else: discard

# --- the table -------------------------------------------------------------

proc find(l: Ledger; key: LedgerKey; pos: var int): bool =
  ## Linear scan of a sorted, short (tens of entries) sequence. `pos` is the
  ## index of the hit, or the insertion point when there is none.
  pos = 0
  while pos < l.entries.len:
    if l.entries[pos].key == key: return true
    if key < l.entries[pos].key: return false
    inc pos
  result = false

proc insertAt(l: var Ledger; pos: int; e: LedgerEntry) =
  l.entries.add e
  var j = l.entries.len - 1
  while j > pos:
    # One element at a time through a local: nimony rejects an assignment whose
    # source and destination are two elements of the same mutable seq.
    var moved = l.entries[j-1]
    l.entries[j] = moved
    dec j
  l.entries[pos] = e

proc put*(l: var Ledger; e: LedgerEntry) =
  ## Insert or replace `e` wholesale. Used by the fragment fold, where the
  ## fragment already carries the accumulated history for its key.
  var pos = 0
  if find(l, e.key, pos):
    l.entries[pos] = e
  else:
    insertAt(l, pos, e)
  l.dirty = true

proc record*(l: var Ledger; key: LedgerKey; s: LedgerSample; toolhash: string) =
  ## Fold one measurement into the average for `key`. A sample taken by a
  ## different build of the tool starts the average over rather than being
  ## averaged with numbers the new binary cannot reproduce.
  var pos = 0
  if find(l, key, pos) and l.entries[pos].toolhash == toolhash:
    l.entries[pos].ewma = blend(l.entries[pos].ewma, s)
    inc l.entries[pos].samples
    l.entries[pos].updated = vfsNow()
  else:
    let e = LedgerEntry(key: key, ewma: s, samples: 1, updated: vfsNow(),
                        toolhash: toolhash)
    # `find` succeeded but the toolhash differed: `pos` is the stale entry, not
    # an insertion point, so overwrite rather than insert a duplicate key.
    if pos < l.entries.len and l.entries[pos].key == key:
      l.entries[pos] = e
    else:
      insertAt(l, pos, e)
  l.dirty = true

proc stampMatches(entryHash, wanted: string): bool {.inline.} =
  ## An empty `wanted` accepts any stamp. That is the door notes/a1a.md §6.4
  ## describes: every tool has its own executable and therefore its own
  ## toolhash, so a process asking what a *different* tool's phase costs -- the
  ## artifact store weighing an entry against the phase that produced it, the
  ## A2b scheduler weighing a spawn -- would filter every entry out if it had to
  ## name a stamp. Asking about oneself still names one and still gets the
  ## reset-on-rebuild behaviour.
  wanted.len == 0 or entryHash == wanted

proc estimate*(l: Ledger; key: LedgerKey; toolhash: string): LedgerSample =
  ## What `key` is expected to cost: its own average, else the average of the
  ## phase across every module, else the table from JIT.md 3.3. Only entries
  ## stamped with `toolhash` count; an empty `toolhash` counts all of them.
  var pos = 0
  if find(l, key, pos) and l.entries[pos].samples > 0 and
      stampMatches(l.entries[pos].toolhash, toolhash):
    return l.entries[pos].ewma
  var acc = default(LedgerSample)
  var n = 0
  for i in 0 ..< l.entries.len:
    if l.entries[i].key.phase == key.phase and l.entries[i].samples > 0 and
        stampMatches(l.entries[i].toolhash, toolhash):
      acc.produceNs += l.entries[i].ewma.produceNs
      acc.serializeNs += l.entries[i].ewma.serializeNs
      acc.writeNs += l.entries[i].ewma.writeNs
      acc.loadNs += l.entries[i].ewma.loadNs
      acc.parseNs += l.entries[i].ewma.parseNs
      acc.spawnNs += l.entries[i].ewma.spawnNs
      acc.bytes += l.entries[i].ewma.bytes
      inc n
  if n > 0:
    result = LedgerSample(
      produceNs: acc.produceNs div n, serializeNs: acc.serializeNs div n,
      writeNs: acc.writeNs div n, loadNs: acc.loadNs div n,
      parseNs: acc.parseNs div n, spawnNs: acc.spawnNs div n,
      bytes: acc.bytes div n)
  else:
    result = defaultSample(key.phase)

proc estimate*(l: Ledger; key: LedgerKey): LedgerSample =
  ## Estimate for the tool running right now.
  estimate(l, key, if l.current.len > 0: l.current else: toolhash())

# --- NIF serialization -----------------------------------------------------
#
# (ledger
#   (entry
#     (phase "hexer") (module "sysvq0asl")
#     (produce ns 13200000) (serialize ns 1800000) (write ns 400000)
#     (load ns 100000) (parse ns 9700000) (spawn ns 3100000)
#     (bytes 1140000) (samples 12) (updated 1757164080000000000)
#     (toolhash "…")))
#
# JIT.md 5.2 sketches the durations as `ms <float>` and `updated` as an ISO
# string. Nanoseconds as integers are what the normative interface block of
# JIT_IMPL.md stores (`produceNs*: int64`, `updated*: int64  # unix ns`), and
# they make the round trip exact -- an average that is re-read and re-averaged
# on every build must not drift through a decimal formatter.

proc addDuration(b: var Builder; tag: string; ns: int64) =
  b.withTree tag:
    b.addIdent "ns"
    b.addIntLit ns

proc writeLedgerFile(l: Ledger; path: string) =
  var b = nifbuilder.open(path)
  b.addHeader "nimony", "ledger"
  b.withTree "ledger":
    for i in 0 ..< l.entries.len:
      b.withTree "entry":
        b.withTree "phase": b.addStrLit l.entries[i].key.phase
        b.withTree "module": b.addStrLit l.entries[i].key.module
        addDuration(b, "produce", l.entries[i].ewma.produceNs)
        addDuration(b, "serialize", l.entries[i].ewma.serializeNs)
        addDuration(b, "write", l.entries[i].ewma.writeNs)
        addDuration(b, "load", l.entries[i].ewma.loadNs)
        addDuration(b, "parse", l.entries[i].ewma.parseNs)
        addDuration(b, "spawn", l.entries[i].ewma.spawnNs)
        b.withTree "bytes": b.addIntLit l.entries[i].ewma.bytes
        b.withTree "samples": b.addIntLit int64(l.entries[i].samples)
        b.withTree "updated": b.addIntLit l.entries[i].updated
        b.withTree "toolhash": b.addStrLit l.entries[i].toolhash
  b.close()

proc setIntField(e: var LedgerEntry; field: string; v: int64) =
  case field
  of "produce": e.ewma.produceNs = v
  of "serialize": e.ewma.serializeNs = v
  of "write": e.ewma.writeNs = v
  of "load": e.ewma.loadNs = v
  of "parse": e.ewma.parseNs = v
  of "spawn": e.ewma.spawnNs = v
  of "bytes": e.ewma.bytes = v
  of "samples": e.samples = int(v)
  of "updated": e.updated = v
  else: discard

proc setStrField(e: var LedgerEntry; field, v: string) =
  case field
  of "phase": e.key.phase = v
  of "module": e.key.module = v
  of "toolhash": e.toolhash = v
  else: discard

proc parseLedgerText(l: var Ledger; content: string) =
  ## Walks the token stream directly: the file has no symbols, no line info and
  ## no pool to intern into, so a `TokenBuf` would only be overhead.
  var r = nifreader.openFromBuffer(content, "")
  var tok = default(ExpandedToken)
  var e = default(LedgerEntry)
  var field = ""
  var depth = 0
  while true:
    r.next(tok)
    case tok.tk
    of EofToken:
      break
    of ParLe:
      let tag = decodeStr(r, tok)
      inc depth
      if depth == 2:
        e = default(LedgerEntry)
      elif depth == 3:
        field = tag
    of ParRi:
      if depth == 3:
        field = ""
      elif depth == 2 and e.key.phase.len > 0:
        put(l, e)
      if depth > 0: dec depth
    of StrLit:
      if depth == 3: setStrField(e, field, decodeStr(r, tok))
    of IntLit:
      if depth == 3: setIntField(e, field, int64(decodeInt(tok)))
    else:
      discard "the `ns` unit marker and anything a later version adds"

proc readLedgerFile(l: var Ledger; path: string): bool =
  ## True when the file was there. One open instead of a stat plus an open:
  ## this runs once in every tool process of every build.
  result = vfsExists(path)
  if result:
    parseLedgerText(l, vfsRead(path))

# --- fragments -------------------------------------------------------------

proc sanitize(s: string): string =
  ## Module suffixes and phase names are identifier-shaped; be defensive about
  ## anything that would leave the fragment directory.
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-'}: result.add c
    else: result.add '_'

proc fragmentDir*(dir: string): string {.inline.} =
  ## The directory holding the fragments a phase writing into `dir` produces.
  dir / FragmentDirName

proc fragmentPath*(dir: string; key: LedgerKey): string =
  ## `<dir>/.ledger/<phase>_<module>.nif`. One file per key means concurrent
  ## tools never write the same path, so no lock is needed on top of the atomic
  ## replace `vfsWrite` already does.
  fragmentDir(dir) / (sanitize(key.phase) & "_" & sanitize(key.module) & ".nif")

proc openFragment*(dir: string; key: LedgerKey): Ledger =
  ## The accumulated history for one key, as a one-entry ledger.
  let p = fragmentPath(dir, key)
  result = Ledger(path: p, entries: @[], current: toolhash(), dirty: false)
  discard readLedgerFile(result, p)

proc writeFragment*(dir: string; key: LedgerKey; s: LedgerSample;
                    toolhash: string) =
  ## Fold one measurement into this key's fragment and publish it. Reading the
  ## previous fragment back is what makes `samples` and the average survive
  ## across runs even when `ledger.nif` has not been written yet.
  let p = fragmentPath(dir, key)
  var l = Ledger(path: p, entries: @[], current: toolhash, dirty: false)
  # Whether the fragment was there also answers whether its directory is, so
  # the steady state pays for no `createDir` path walk. This runs in every tool
  # process of every build; the syscalls are the whole cost.
  let existed = readLedgerFile(l, p)
  record(l, key, s, toolhash)
  if not existed: ensureDir(fragmentDir(dir))
  writeLedgerFile(l, p)

proc foldSpawn(l: var Ledger; key: LedgerKey; spawnNs: int64; observer: string) =
  ## Blend a spawn observation into `key`'s entry, creating one under the
  ## observer's stamp only when there is nothing to blend into.
  var pos = 0
  if find(l, key, pos):
    if l.entries[pos].ewma.spawnNs == 0:
      # First observation for this key. Zero is not a measurement -- no process
      # has ever started in zero nanoseconds -- it is the tool saying "I do not
      # measure this about myself", so the observation seeds the average
      # instead of being blended against it. Blending would start every key a
      # factor of three low and take a dozen builds to converge.
      l.entries[pos].ewma.spawnNs = spawnNs
    else:
      l.entries[pos].ewma.spawnNs = ewmaStep(l.entries[pos].ewma.spawnNs, spawnNs)
    l.entries[pos].updated = vfsNow()
    l.dirty = true
  else:
    var s = default(LedgerSample)
    s.spawnNs = spawnNs
    record(l, key, s, observer)

proc recordSpawn*(dir: string; key: LedgerKey; spawnNs: int64;
                  observer: string) =
  ## Attach a spawn cost to a key another process measured. The sample count is
  ## deliberately not bumped: the spawn is an observation *about* the sample the
  ## tool itself recorded, not a second one.
  ##
  ## `observer` is the toolhash of whoever is *watching* -- nifmake, not the
  ## tool -- and it is used only to stamp an entry this call has to create from
  ## nothing (`cc` and `link` report no `produce` of their own). An entry that
  ## already exists keeps the toolhash of the process that measured it, whatever
  ## that is. Restamping it would be a lie about who took the measurement, and
  ## restarting its average would throw away the tool's numbers on every build:
  ## an observer's hash can never match the observed tool's.
  let p = fragmentPath(dir, key)
  var l = Ledger(path: p, entries: @[], current: observer, dirty: false)
  let existed = readLedgerFile(l, p)
  foldSpawn(l, key, spawnNs, observer)
  if not existed: ensureDir(fragmentDir(dir))
  writeLedgerFile(l, p)

proc recordSpawnWall*(dir: string; phase, module: string; wallNs: int64;
                      observer: string) =
  ## What a *command* cost, as seen from outside it: `spawn` is the wall time
  ## the process took minus the `produce` the tool inside it reported.
  ##
  ## This is nifmake's half of JIT.md 5.2. It runs once per executed command, so
  ## it is one `vfsExists` plus one `vfsRead` plus one atomic write -- the same
  ## budget `writeFragment` costs the tool itself.
  ##
  ## Two keys are probed before anything is created. A whole-program node keys
  ## its own fragment with an empty module (`dceLive` does), while an observer
  ## outside the tool can only derive a module suffix from the node's output
  ## file. Probing `(phase, module)` and then `(phase, "")` lands the spawn on
  ## the sample the tool actually took instead of opening a second entry beside
  ## it; the extra probe is one `vfsExists` and only on the nodes that need it.
  ##
  ## The `produce` subtracted is the fragment's running average, not this run's
  ## raw measurement: a separate process cannot see the latter, and the tool has
  ## just folded the latter into the former. The difference is damped again by
  ## the EWMA the spawn itself goes through. When no fragment exists at all --
  ## `cc`, `link`, and anything else that is not one of our instrumented tools
  ## -- the whole wall time is the spawn cost, which is the honest answer for a
  ## node that can never run in-process.
  var key = LedgerKey(phase: phase, module: module)
  var p = fragmentPath(dir, key)
  var l = Ledger(path: p, entries: @[], current: observer, dirty: false)
  var existed = readLedgerFile(l, p)
  if not existed and module.len > 0:
    let whole = LedgerKey(phase: phase, module: "")
    let wp = fragmentPath(dir, whole)
    if readLedgerFile(l, wp):
      key = whole
      p = wp
      existed = true
  var produceNs = 0'i64
  var pos = 0
  if find(l, key, pos): produceNs = l.entries[pos].ewma.produceNs
  var spawnNs = wallNs - produceNs
  if spawnNs < 0: spawnNs = 0
  foldSpawn(l, key, spawnNs, observer)
  if not existed: ensureDir(fragmentDir(dir))
  writeLedgerFile(l, p)

proc foldFragments(l: var Ledger; dir: string) =
  var files: seq[string] = @[]
  addNifFiles(fragmentDir(dir), files)
  for i in 0 ..< files.len:
    parseLedgerText(l, vfsRead(files[i]))

# --- the public entry points ----------------------------------------------

proc openLedger*(path: string): Ledger =
  ## `path` is `<nimcache>/ledger.nif`; a missing file yields an empty ledger.
  ## The fragments below the nimcache -- its own `.ledger/` and one directory
  ## level down, where the backend phases write -- are folded in on top.
  result = Ledger(path: path, entries: @[], current: toolhash(), dirty: false)
  discard readLedgerFile(result, path)
  let root = path.parentDir
  foldFragments(result, root)
  var subdirs: seq[string] = @[]
  addSubdirs(root, subdirs)
  for i in 0 ..< subdirs.len:
    if subdirs[i].extractFilename != FragmentDirName:
      foldFragments(result, subdirs[i])
  result.dirty = false

proc saveLedger*(l: var Ledger) =
  ## Publish the folded table. Atomic: `vfsWrite` writes a sibling temp file and
  ## renames it over the target.
  if l.path.len == 0: return
  ensureDir(l.path.parentDir)
  writeLedgerFile(l, l.path)
  l.dirty = false

proc consolidate*(nimcache: string) =
  ## Fold every fragment under `nimcache` into `<nimcache>/ledger.nif`. The
  ## fragments are left alone: they, not the snapshot, carry each key's history,
  ## and deleting them would restart every average at one sample. For phase A1d,
  ## where nifmake calls this at the end of a run.
  var l = openLedger(nimcache / "ledger.nif")
  if l.entries.len > 0:
    saveLedger l

# --- reporting -------------------------------------------------------------

type
  PhaseTotals* = object
    ## One row of the `--stats` table: the keys of a phase, folded together.
    phase*: string
    keys*: int      ## how many (phase, module) pairs contributed
    samples*: int   ## measurements behind them
    produceNs*, serializeNs*, writeNs*, loadNs*, parseNs*, spawnNs*: int64
                    ## means over the keys
    bytes*: int64   ## sum over the keys

proc phaseTotals*(l: Ledger): seq[PhaseTotals] =
  ## `l.entries` is sorted by (phase, module), so one pass groups it.
  result = @[]
  var i = 0
  while i < l.entries.len:
    var t = PhaseTotals(phase: l.entries[i].key.phase)
    while i < l.entries.len and l.entries[i].key.phase == t.phase:
      inc t.keys
      t.samples += l.entries[i].samples
      t.produceNs += l.entries[i].ewma.produceNs
      t.serializeNs += l.entries[i].ewma.serializeNs
      t.writeNs += l.entries[i].ewma.writeNs
      t.loadNs += l.entries[i].ewma.loadNs
      t.parseNs += l.entries[i].ewma.parseNs
      t.spawnNs += l.entries[i].ewma.spawnNs
      t.bytes += l.entries[i].ewma.bytes
      inc i
    if t.keys > 0:
      t.produceNs = t.produceNs div t.keys
      t.serializeNs = t.serializeNs div t.keys
      t.writeNs = t.writeNs div t.keys
      t.loadNs = t.loadNs div t.keys
      t.parseNs = t.parseNs div t.keys
      t.spawnNs = t.spawnNs div t.keys
    result.add t

proc formatMs*(ns: int64): string =
  ## Milliseconds with one decimal. Integer arithmetic so that no float
  ## formatter (and no locale) gets between the ledger and the report.
  let tenths = (ns + 50_000'i64) div 100_000'i64
  result = $(tenths div 10) & "." & $(tenths mod 10)

proc padTo(s: string; n: int; left: bool): string =
  if s.len >= n:
    result = s
  elif left:
    result = ""
    for _ in 0 ..< n - s.len: result.add ' '
    result.add s
  else:
    result = s
    for _ in 0 ..< n - s.len: result.add ' '

proc statsTable*(l: Ledger): string =
  ## The per-phase table `nimony --stats` prints (JIT.md 5.2, "Report"): the
  ## averages the build just fed into the ledger, one row per phase.
  result = ""
  let rows = phaseTotals(l)
  if rows.len == 0: return
  ##
  ## `spawn ms` is what the process behind the phase cost on top of the work it
  ## did: nifmake measures the wall time of the command and subtracts the
  ## `produce` the tool reported from inside it (A1d). For `cc` and `link`,
  ## which report no `produce` of their own, it is the whole command.
  ##
  ## It is wall time, and nimony runs nifmake with `-j`, so on a wide DAG depth
  ## it also carries the CPU contention of the fan-out. That is the number the
  ## scheduler wants -- what a process costs *in this build* is what decides
  ## whether the node is worth one -- but it is not process startup in
  ## isolation, and a busy depth reads higher than an idle one.
  result = "[stats] " & padTo("phase", 10, false) & padTo("samples", 9, true) &
           padTo("produce ms", 13, true) & padTo("spawn ms", 11, true) &
           padTo("ser+parse ms", 14, true) &
           padTo("write ms", 10, true) & padTo("bytes", 12, true)
  for i in 0 ..< rows.len:
    result.add "\n[stats] " & padTo(rows[i].phase, 10, false) &
      padTo($rows[i].samples, 9, true) &
      padTo(formatMs(rows[i].produceNs), 13, true) &
      padTo(formatMs(rows[i].spawnNs), 11, true) &
      padTo(formatMs(rows[i].serializeNs + rows[i].parseNs), 14, true) &
      padTo(formatMs(rows[i].writeNs), 10, true) &
      padTo($rows[i].bytes, 12, true)

# --- instrumentation -------------------------------------------------------

type
  PhaseTimer* = object
    ## Threaded through a tool's entry point. Holds the running sample and the
    ## monotonic mark the next `note*` measures from; a phase costs a handful of
    ## clock reads plus one small file write, whatever it does.
    key: LedgerKey
    dir: string       ## where the phase writes, i.e. where its fragment goes
    outFile: string
    sample: LedgerSample
    mark: int64
    active: bool

proc initPhaseTimer*(dir, phase, module: string): PhaseTimer =
  result = PhaseTimer(key: LedgerKey(phase: phase, module: module),
                      dir: dir, outFile: "", sample: default(LedgerSample),
                      mark: monoNs(), active: dir.len > 0 and phase.len > 0)

proc mark*(t: var PhaseTimer) {.inline.} =
  ## Start of the next measured region. `note*` measures from here and moves the
  ## mark forward, so consecutive regions need one `mark` in total.
  if t.active: t.mark = monoNs()

proc take(t: var PhaseTimer): int64 {.inline.} =
  let now = monoNs()
  result = now - t.mark
  t.mark = now

proc noteLoad*(t: var PhaseTimer) {.inline.} =
  if t.active: t.sample.loadNs += take(t)
proc noteParse*(t: var PhaseTimer) {.inline.} =
  if t.active: t.sample.parseNs += take(t)
proc noteProduce*(t: var PhaseTimer) {.inline.} =
  if t.active: t.sample.produceNs += take(t)
proc noteSerialize*(t: var PhaseTimer) {.inline.} =
  if t.active: t.sample.serializeNs += take(t)
proc noteWrite*(t: var PhaseTimer) {.inline.} =
  if t.active: t.sample.writeNs += take(t)

proc noteBytes*(t: var PhaseTimer; n: int64) {.inline.} =
  if t.active: t.sample.bytes += n

proc noteOutput*(t: var PhaseTimer; path: string) {.inline.} =
  ## Size the phase's output at `finish` time rather than now, so a caller can
  ## name the file before it exists.
  if t.active: t.outFile = path

proc setModule*(t: var PhaseTimer; module: string) {.inline.} =
  ## Tools that learn the module suffix only while running.
  if t.active: t.key.module = module

proc finish*(t: var PhaseTimer) =
  ## Publish the fragment. Called once, at the end of the tool.
  if not t.active: return
  t.active = false
  if t.outFile.len > 0:
    t.sample.bytes += fileSizeOrZero(t.outFile)
  writeFragment(t.dir, t.key, t.sample, toolhash())
