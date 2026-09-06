## Custom runner for the cost ledger (JIT.md 5.2, JIT_IMPL.md phase A1a).
##
## Two halves. The unit half drives `src/lib/ledger.nim` directly: the EWMA
## arithmetic, the fallback order of `estimate`, the NIF round trip, the
## fragment fold, the toolhash reset, and (A1d) the spawn observation nifmake
## folds in from outside a tool's process. The integration half compiles
## `hello.nim` with the real toolchain and checks that the tools left usable
## samples behind, that nifmake attached a spawn cost to every command it ran
## and consolidated the snapshot without anybody asking for `--stats`, and that
## `--stats` prints the table with its spawn column.
##
## Needs a built `bin/nimony` (the tree walk's `tests/setup.hastur` provides it).

import std / [os, strutils, osproc]
import "../../src/hastur/context"
import "../../src/lib/ledger"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")
let testDir = if arg("dir").len > 0: arg("dir") else: "tests/ledger"

var failures = 0

template expect(cond: bool; msg: string) =
  if not cond:
    inc failures
    echo "[ledger] FAIL: ", msg

const
  HashA = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  HashB = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

proc sample(produce: int64; bytes: int64 = 0): LedgerSample =
  result = default(LedgerSample)
  result.produceNs = produce
  result.bytes = bytes

proc key(phase, module: string): LedgerKey =
  LedgerKey(phase: phase, module: module)

let scratch = nimcacheDir / "ledgertests"
removeDir scratch
createDir scratch

# --- 1. EWMA arithmetic ----------------------------------------------------
#
# alpha = 0.3, i.e. `new = (7*old + 3*x) / 10` in integer nanoseconds.

block ewmaArithmetic:
  var l = Ledger(path: scratch / "unit.nif", entries: @[], current: HashA)
  let k = key("hexer", "m1")
  record(l, k, sample(10_000_000), HashA)
  expect l.entries.len == 1, "first record must create the entry"
  expect l.entries[0].samples == 1, "first record must be one sample"
  expect l.entries[0].ewma.produceNs == 10_000_000,
    "first sample is the average: " & $l.entries[0].ewma.produceNs

  record(l, k, sample(20_000_000), HashA)
  # (7*10ms + 3*20ms) / 10 = 13ms
  expect l.entries[0].samples == 2, "second record must count"
  expect l.entries[0].ewma.produceNs == 13_000_000,
    "EWMA after 10ms,20ms must be 13ms, got " & $l.entries[0].ewma.produceNs

  record(l, k, sample(20_000_000), HashA)
  # (7*13ms + 3*20ms) / 10 = 15.1ms
  expect l.entries[0].ewma.produceNs == 15_100_000,
    "EWMA after a third 20ms must be 15.1ms, got " & $l.entries[0].ewma.produceNs
  expect l.entries[0].samples == 3, "three samples"

# --- 2. estimate: own entry, then phase mean, then the default table -------

block estimateFallback:
  var l = Ledger(path: scratch / "est.nif", entries: @[], current: HashA)
  # 2a. the default table (JIT.md 3.3) when nothing was ever measured
  expect estimate(l, key("cc", "m1"), HashA).produceNs == 54_000_000,
    "cc must fall back to 54 ms"
  expect estimate(l, key("link", ""), HashA).produceNs == 33_000_000,
    "link must fall back to 33 ms"
  expect estimate(l, key("nifler", "m1"), HashA).spawnNs == 3_000_000,
    "every default carries the 3 ms spawn"
  expect estimate(l, key("nosuchphase", ""), HashA).produceNs == 0,
    "an unknown phase has no default produce"

  # 2b. the phase-wide mean once other modules of the phase are known
  record(l, key("lengc", "m1"), sample(4_000_000), HashA)
  record(l, key("lengc", "m2"), sample(8_000_000), HashA)
  expect estimate(l, key("lengc", "m3"), HashA).produceNs == 6_000_000,
    "an unmeasured module gets the phase mean, got " &
      $estimate(l, key("lengc", "m3"), HashA).produceNs

  # 2c. the entry itself wins over the mean
  record(l, key("lengc", "m3"), sample(100_000_000), HashA)
  expect estimate(l, key("lengc", "m3"), HashA).produceNs == 100_000_000,
    "a measured module uses its own average"

# --- 3. toolhash: a sample from another tool build is not an estimate ------

block toolhashReset:
  var l = Ledger(path: scratch / "th.nif", entries: @[], current: HashA)
  record(l, key("nimsem", "m1"), sample(50_000_000), HashB)
  expect l.entries.len == 1, "the entry is kept on disk"
  expect estimate(l, key("nimsem", "m1"), HashA).produceNs == 7_000_000,
    "an entry under another toolhash falls through to the default, got " &
      $estimate(l, key("nimsem", "m1"), HashA).produceNs
  expect estimate(l, key("nimsem", "m1"), HashB).produceNs == 50_000_000,
    "the same entry is usable for the tool that recorded it"
  # A sample from a new build restarts the average rather than blending.
  record(l, key("nimsem", "m1"), sample(10_000_000), HashA)
  expect l.entries[0].samples == 1, "a toolchain change resets the sample count"
  expect l.entries[0].ewma.produceNs == 10_000_000,
    "a toolchain change resets the average"

# --- 4. NIF round trip -----------------------------------------------------

block nifRoundTrip:
  var l = Ledger(path: scratch / "rt" / "ledger.nif", entries: @[], current: HashA)
  record(l, key("hexer", "aaa"), sample(1_234_567, 4096), HashA)
  record(l, key("hexer", "aaa"), sample(2_000_000, 8192), HashA)
  record(l, key("nimsem", "bbb"), sample(7_654_321, 999), HashA)
  record(l, key("dceLive", ""), sample(42, 1), HashB)
  saveLedger l
  expect fileExists(l.path), "saveLedger must write the file"

  let back = openLedger(l.path)
  expect back.entries.len == l.entries.len,
    "round trip must keep every entry: " & $back.entries.len
  for i in 0 ..< min(back.entries.len, l.entries.len):
    expect back.entries[i].key == l.entries[i].key, "key " & $i & " survives"
    expect back.entries[i].ewma.produceNs == l.entries[i].ewma.produceNs,
      "produce of " & back.entries[i].key.phase & " survives exactly"
    expect back.entries[i].ewma.bytes == l.entries[i].ewma.bytes,
      "bytes of " & back.entries[i].key.phase & " survives exactly"
    expect back.entries[i].samples == l.entries[i].samples,
      "sample count of " & back.entries[i].key.phase & " survives"
    expect back.entries[i].updated == l.entries[i].updated,
      "timestamp of " & back.entries[i].key.phase & " survives exactly"
    expect back.entries[i].toolhash == l.entries[i].toolhash,
      "toolhash of " & back.entries[i].key.phase & " survives"
  # Entries are stored sorted, so the file order is reproducible.
  expect back.entries[0].key.phase == "dceLive", "entries come back sorted"

# --- 5. fragments: three keys, then a second sample for one of them --------

block fragmentFold:
  let dir = scratch / "frag"
  createDir dir
  writeFragment(dir, key("nifler", "m1"), sample(1_000_000, 10), HashA)
  writeFragment(dir, key("nimsem", "m1"), sample(2_000_000, 20), HashA)
  writeFragment(dir, key("hexer", "m1"), sample(3_000_000, 30), HashA)
  var l = openLedger(dir / "ledger.nif")
  expect l.entries.len == 3, "three fragments fold to three entries, got " & $l.entries.len
  expect estimate(l, key("hexer", "m1"), HashA).produceNs == 3_000_000,
    "a folded fragment is the estimate"

  # A second sample for the same key accumulates in that key's own fragment.
  writeFragment(dir, key("hexer", "m1"), sample(13_000_000, 130), HashA)
  l = openLedger(dir / "ledger.nif")
  expect l.entries.len == 3, "a second sample adds no entry"
  var pos = -1
  for i in 0 ..< l.entries.len:
    if l.entries[i].key == key("hexer", "m1"): pos = i
  expect pos >= 0, "the hexer entry is still there"
  if pos >= 0:
    expect l.entries[pos].samples == 2,
      "the fragment accumulates: " & $l.entries[pos].samples
    # (7*3ms + 3*13ms) / 10 = 6ms
    expect l.entries[pos].ewma.produceNs == 6_000_000,
      "the average moved to 6 ms, got " & $l.entries[pos].ewma.produceNs

  # A fragment written one directory down (where the backend phases write) is
  # folded too.
  let sub = dir / "main_c"
  createDir sub
  writeFragment(sub, key("lengc", "m1"), sample(6_000_000, 60), HashA)
  l = openLedger(dir / "ledger.nif")
  expect l.entries.len == 4, "a fragment below a subdirectory is folded, got " & $l.entries.len

# --- 5b. spawn: what nifmake sees from outside the process (A1d) -----------
#
# `spawn` is the one measurement a tool cannot take about itself. nifmake
# collects it in a `SpawnLog` during a run and folds it into the snapshot at
# the end, so the cases here drive that pair rather than a per-command write.

proc spawnOf(l: Ledger; phase, module: string): int64 =
  result = -1
  for i in 0 ..< l.entries.len:
    if l.entries[i].key == key(phase, module): result = l.entries[i].ewma.spawnNs

block spawnRecording:
  let nc = scratch / "spawn"
  createDir nc
  # The tool measured 6 ms of work; the process it ran in took 10 ms wall. The
  # difference is what the process itself cost.
  writeFragment(nc, key("hexer", "m1"), sample(6_000_000, 100), HashA)
  var log = default(SpawnLog)
  log.noteSpawn("hexer", "m1", 10_000_000)
  consolidate(nc, log)

  var l = openLedger(nc / "ledger.nif")
  expect spawnOf(l, "hexer", "m1") == 4_000_000,
    "spawn is wall minus produce, got " & $spawnOf(l, "hexer", "m1")
  var pos = -1
  for i in 0 ..< l.entries.len:
    if l.entries[i].key == key("hexer", "m1"): pos = i
  if pos >= 0:
    expect l.entries[pos].ewma.produceNs == 6_000_000,
      "and the tool's produce is untouched"
    expect l.entries[pos].samples == 1,
      "an observation about a sample is not a second sample"
    # The observer is a different binary than the tool -- nifmake's `toolhash`
    # can never equal hexer's -- so an entry that got restamped here would have
    # its average restarted by the watcher on every single build.
    expect l.entries[pos].toolhash == HashA,
      "the entry keeps the stamp of whoever measured it, got " &
        l.entries[pos].toolhash

  # The next build rewrites the fragment (which still reports no spawn of its
  # own) and observes again. The spawn must survive the fold and then blend:
  # (7*4ms + 3*14ms) / 10 = 7 ms.
  writeFragment(nc, key("hexer", "m1"), sample(6_000_000, 100), HashA)
  var log2 = default(SpawnLog)
  log2.noteSpawn("hexer", "m1", 20_000_000)
  consolidate(nc, log2)
  l = openLedger(nc / "ledger.nif")
  expect spawnOf(l, "hexer", "m1") == 7_000_000,
    "a fragment fold must not clobber the spawn, and the second observation " &
      "blends: got " & $spawnOf(l, "hexer", "m1")

  # A tool that reports nothing -- `cc`, `link` -- gives the whole wall time.
  var log3 = default(SpawnLog)
  log3.noteSpawn("cc", "m1", 54_000_000)
  consolidate(nc, log3)
  l = openLedger(nc / "ledger.nif")
  expect spawnOf(l, "cc", "m1") == 54_000_000,
    "an unreported phase contributes its whole command, got " &
      $spawnOf(l, "cc", "m1")

  # A whole-program node keys its own sample with an empty module (hexer's `dl`
  # does), while nifmake can only derive a module from the output file. The
  # observation has to find the tool's sample rather than open a second one.
  writeFragment(nc, key("dceLive", ""), sample(8_000_000, 10), HashA)
  var log4 = default(SpawnLog)
  log4.noteSpawn("dceLive", "mainmod", 9_000_000)
  consolidate(nc, log4)
  l = openLedger(nc / "ledger.nif")
  expect spawnOf(l, "dceLive", "mainmod") == -1,
    "no second entry is opened beside the tool's"
  expect spawnOf(l, "dceLive", "") == 1_000_000,
    "the spawn landed on the whole-program key, got " &
      $spawnOf(l, "dceLive", "")

  # A wall time below the reported produce (a produce average that has not
  # caught up, a clock that disagrees with itself) is a zero spawn, never
  # negative.
  writeFragment(nc, key("nimsem", "m2"), sample(50_000_000), HashA)
  var log5 = default(SpawnLog)
  log5.noteSpawn("nimsem", "m2", 10_000_000)
  consolidate(nc, log5)
  l = openLedger(nc / "ledger.nif")
  expect spawnOf(l, "nimsem", "m2") == 0,
    "a wall time below produce clamps to zero, got " &
      $spawnOf(l, "nimsem", "m2")

  # A rebuilt tool restarts its spawn average with the rest of its numbers.
  writeFragment(nc, key("hexer", "m1"), sample(6_000_000, 100), HashB)
  l = openLedger(nc / "ledger.nif")
  expect spawnOf(l, "hexer", "m1") == 0,
    "a changed toolhash drops the spawn the old binary earned, got " &
      $spawnOf(l, "hexer", "m1")

  # `recordSpawn` is the per-key form, for a caller that has one observation
  # and a fragment to put it in rather than a whole run's worth.
  let one = scratch / "spawn1"
  createDir one
  writeFragment(one, key("lengc", "m1"), sample(5_000_000, 10), HashA)
  recordSpawn(one, key("lengc", "m1"), 2_000_000, HashB)
  let f = openFragment(one, key("lengc", "m1"))
  if f.entries.len == 1:
    expect f.entries[0].ewma.spawnNs == 2_000_000,
      "the first observation seeds the average, got " &
        $f.entries[0].ewma.spawnNs
    expect f.entries[0].toolhash == HashA,
      "and does not restamp the entry"

# --- 5c. consolidate: the snapshot nifmake publishes ------------------------

block consolidation:
  let nc = scratch / "consolidate"
  createDir nc
  let backend = nc / "main_c"
  createDir backend
  writeFragment(nc, key("nifler", "m1"), sample(1_000_000, 10), HashA)
  writeFragment(nc, key("nimsem", "m1"), sample(2_000_000, 20), HashA)
  writeFragment(backend, key("lengc", "m1"), sample(3_000_000, 30), HashA)
  expect not fileExists(nc / "ledger.nif"), "nothing published yet"
  consolidate(nc)
  expect fileExists(nc / "ledger.nif"),
    "consolidate publishes <nimcache>/ledger.nif"
  # The fragments stay: they, not the snapshot, carry each key's history, and
  # deleting them would restart every average at one sample on the next build.
  expect fileExists(fragmentPath(nc, key("nifler", "m1"))),
    "and leaves the fragments alone"
  let snap = openLedger(nc / "ledger.nif")
  expect snap.entries.len == 3,
    "the snapshot holds both directory levels, got " & $snap.entries.len

# --- 6. the report ---------------------------------------------------------

block statsRendering:
  var l = Ledger(path: scratch / "rep.nif", entries: @[], current: HashA)
  record(l, key("hexer", "a"), sample(1_500_000, 100), HashA)
  record(l, key("hexer", "b"), sample(2_500_000, 200), HashA)
  var spawned = sample(3_000_000, 50)
  spawned.spawnNs = 4_400_000
  record(l, key("cc", "a"), spawned, HashA)
  let t = statsTable(l)
  expect t.contains("[stats] phase"), "the table has a header"
  expect t.contains("hexer"), "the table has the phase"
  expect t.contains("2.0"), "hexer's mean produce is 2.0 ms:\n" & t
  expect t.contains("300"), "hexer's bytes are summed:\n" & t
  expect t.contains("spawn ms"), "the table has a spawn column (A1d):\n" & t
  expect t.contains("4.4"), "and prints the spawn average in it:\n" & t
  expect formatMs(0) == "0.0", "formatMs(0)"
  expect formatMs(1_234_567) == "1.2", "formatMs rounds to a tenth of a ms"

# --- 7. integration: a real build fills the ledger --------------------------

let nimony = toolchainDir / "nimony".addFileExt(ExeExt)
if not fileExists(nimony):
  echo "[ledger] FAIL: no toolchain at ", nimony
  inc failures
else:
  let buildCache = scratch / "build"
  let src = testDir / "hello.nim"
  let cmd = quoteShell(nimony) & " c --silentMake --nimcache:" &
            quoteShell(buildCache) & " " & quoteShell(src)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo "[ledger] FAIL: compiling ", src, " failed:\n", output
    inc failures
  else:
    # nifmake consolidates at the end of every run that spawned something, so
    # the snapshot is there without anybody having asked for `--stats`.
    expect fileExists(buildCache / "ledger.nif"),
      "nifmake publishes <nimcache>/ledger.nif on its own"

    let l = openLedger(buildCache / "ledger.nif")
    for phase in ["nifler", "nimsem", "hexer", "lengc"]:
      var found = false
      for i in 0 ..< l.entries.len:
        if l.entries[i].key.phase == phase:
          found = true
          expect l.entries[i].ewma.produceNs > 0,
            phase & "/" & l.entries[i].key.module & " must have a produce time"
          expect l.entries[i].ewma.bytes > 0,
            phase & "/" & l.entries[i].key.module & " must have output bytes"
          expect l.entries[i].toolhash.len == 40,
            phase & " must be stamped with a toolhash"
      expect found, "the build must leave a " & phase & " sample behind"

    # Every command nifmake ran cost a process, and it measured what that was
    # worth (A1d). `cc` is in the list because it is the case with no fragment
    # of its own: the whole wall time is its spawn cost.
    for phase in ["nifler", "nimsem", "hexer", "lengc", "cc"]:
      var found = false
      var spawned = false
      for i in 0 ..< l.entries.len:
        if l.entries[i].key.phase == phase:
          found = true
          if l.entries[i].ewma.spawnNs > 0: spawned = true
      expect found, "the build must leave a " & phase & " sample behind"
      expect spawned, "nifmake must record a spawn cost for " & phase

    # The frontend phases write into the nimcache itself.
    for phase in ["nifler", "nimsem", "hexer"]:
      expect fileExists(fragmentPath(buildCache,
                                     key(phase, moduleSuffixOf(src)))) or
             dirExists(fragmentDir(buildCache)),
        "the nimcache holds a " & phase & " fragment directory"

    # `--stats` prints the line-count summary AND the phase table.
    let (statsOut, statsCode) = execCmdEx(quoteShell(nimony) &
      " c --stats --silentMake --nimcache:" & quoteShell(buildCache) & " " &
      quoteShell(src))
    if statsCode != 0:
      echo "[ledger] FAIL: --stats build failed:\n", statsOut
      inc failures
    else:
      expect statsOut.contains(" modules, "),
        "the existing --stats line-count output is kept:\n" & statsOut
      expect statsOut.contains("[stats] phase"),
        "--stats prints the ledger table header:\n" & statsOut
      expect statsOut.contains("spawn ms"),
        "--stats prints the spawn column (A1d):\n" & statsOut
      expect statsOut.contains("nimsem"),
        "--stats names the phases:\n" & statsOut
      expect statsOut.contains("[store] policy="),
        "--stats prints the artifact store line beside it (A1d):\n" & statsOut
      expect fileExists(buildCache / "ledger.nif"),
        "--stats publishes the ledger snapshot"

if failures > 0:
  quit "FAILURE: " & $failures & " ledger test(s) failed"
echo "[ledger] all ledger tests passed"
