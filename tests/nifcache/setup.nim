## Custom runner: a cache write must never truncate a file a reader has MMAP'D.
##
## `nifreader.open` and `bif.load` both mmap the cache entry they read, and
## `load` deliberately BORROWS the mapped token block for the process lifetime
## rather than copying it. Any writer that replaces such a file with a
## truncating `fmWrite` open invalidates those pages immediately — the reader
## takes SIGBUS past the new EOF, or reads torn bytes in the window before the
## new content lands.
##
## No race is needed to show it: truncation invalidates the mapping at once, so
## one process suffices — store, mmap, store again, then touch the mapping.
## That determinism is why this is a test and not a stress rig; against a
## truncating writer both cases below die with SIGBUS every time.
##
## Two surfaces, because there are two writers: `bif.store` (binary `.bif`) and
## `vfs.vfsWrite` (the relay behind every `.nif` / `.idx.nif` write — nifpools,
## nifindexes, nifbuilder, nifmake).
##
## A third case drives the whole toolchain instead of the library: the same
## sources are compiled under `--vfs:disk` and under `--vfs:verify` into the
## same nimcache path, and every `.nif` the build leaves behind must come out
## byte for byte the same. `--vfs:verify` is the mode that makes a store that
## disagrees with the disk a fatal diagnostic rather than a stale build, so a
## clean run of it plus identical bytes is the phase's gate (JIT_IMPL.md A1b).
##
## The nimcache PATH is shared between the two runs on purpose: several
## artifacts legitimately embed the absolute cache directory (the CTFE
## sub-program bakes in the `<sfx>.out.nif` it writes at run time), so two
## caches in two directories differ for a reason that has nothing to do with
## the VFS mode. Wiping one directory between the runs compares the modes and
## nothing else.

import std / [os, strutils, osproc, algorithm, tables]
import "../../src/lib/vfs"
import "../../src/lib/bif"
import "../../src/lib/nifcore"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

let toolchainDir = if arg("bindir").len > 0: arg("bindir") else: "bin"
let cacheRoot = if arg("cachedir").len > 0: arg("cachedir") else: "nimcache"

var failures = 0

proc fail(msg: string) =
  echo "  FAIL: ", msg
  inc failures

proc ok(msg: string) =
  echo "  ok: ", msg

proc tempsLeft(target: string): seq[string] =
  ## `.tmp.<pid>.<n>` siblings of `target`. The temp must be gone on the
  ## success path AND the failure path; a leftover would also be picked up by
  ## directory scans looking for outputs.
  result = @[]
  let dir = target.parentDir
  let prefix = target.extractFilename & ".tmp."
  for kind, p in walkDir(if dir.len > 0: dir else: "."):
    if kind == pcFile and p.extractFilename.startsWith(prefix):
      result.add p

# ── surface 1: bif.store, whose mapping is borrowed for the process lifetime ──

proc buildBuf(n: int): TokenBuf =
  result = createTokenBuf(16)
  let tStmts = result.tags.registerTag("stmts")
  let tCall = result.tags.registerTag("call")
  let f = result.pool.filenames.getOrIncl("some/where.nim")
  result.buildTree tStmts:
    result.appendLineInfo f, 1'i32, 0'i32
    for i in 0 ..< n:
      result.buildTree tCall:
        result.addSymUse "some.long.symbol.name.0"
        result.addIntLit int64(i)
        result.addStrLit "a longer interned string"

proc bifCase() =
  echo "bif.store replaces a mapped .bif without truncating it"
  let path = getTempDir() / "nifcache_bif_atomic.bif"
  removeFile path

  var big = buildBuf(50_000)
  store(big, path)
  let bigSize = getFileSize(path)

  var m = load(path)                    # mmap + borrow the token block
  let n = m.buf.len
  if n == 0:
    fail "loaded an empty token buffer"
    return

  var small = buildBuf(10)              # a second writer, a SMALLER file
  store(small, path)
  if getFileSize(path) >= bigSize:
    fail "the second store did not shrink the file; the test proves nothing"

  # Touch every token of the mapping taken before the rewrite. Under a
  # truncating writer this is a SIGBUS, not a wrong answer.
  var acc = 0'u32
  for i in 0 ..< n: acc = acc xor uint32(m.buf[i])
  ok "the borrowed token block survived a smaller rewrite (" & $n & " tokens)"

  let leftovers = tempsLeft(path)
  if leftovers.len > 0: fail "temp files left behind: " & $leftovers
  else: ok "no .tmp.* residue"
  removeFile path

# ── surface 2: vfsWrite, the relay behind every .nif write ───────────────────

proc vfsCase() =
  echo "vfsWrite replaces a mapped .nif without truncating it"
  let path = getTempDir() / "nifcache_vfs_atomic.nif"
  removeFile path

  var big = newStringOfCap(200_000)
  for i in 0 ..< 200_000: big.add 'x'
  vfsWrite(path, big)

  let blob = vfsOpenMmap(path)
  let size = blob.size
  if size != 200_000:
    fail "mmap reported " & $size & " bytes, expected 200000"
    return

  vfsWrite(path, "short\n")
  if getFileSize(path) >= size:
    fail "the rewrite did not shrink the file; the test proves nothing"

  var sum = 0
  let data = cast[ptr UncheckedArray[char]](blob.data)
  for i in 0 ..< size: sum = sum + int(data[i])
  if sum != 200_000 * int('x'):
    fail "the mapping's bytes changed under us (sum " & $sum & ")"
  else:
    ok "the held mapping still reads its original bytes (" & $size & " bytes)"

  let leftovers = tempsLeft(path)
  if leftovers.len > 0: fail "temp files left behind: " & $leftovers
  else: ok "no .tmp.* residue"
  removeFile path

# ── surface 3: the toolchain, once per --vfs mode ────────────────────────────

proc artifactSnapshot(cache: string): Table[string, string] =
  ## Every `.nif` under `cache`, keyed by its path relative to `cache`. The
  ## bytes rather than a digest: a difference has to be reportable, and these
  ## caches are a few hundred small files.
  ## The cost ledger (`.ledger/*.nif`, `ledger.nif`) is excluded: it holds
  ## the timings of the run that wrote it, which differ between any two runs
  ## by construction and say nothing about the VFS mode.
  result = initTable[string, string]()
  for path in walkDirRec(cache):
    if path.endsWith(".nif"):
      let rel = path.relativePath(cache)
      if rel.startsWith(".ledger") or rel.contains(DirSep & ".ledger" & DirSep) or
          rel.endsWith("ledger.nif"):
        continue
      result[rel] = readFile(path)

proc compileUnder(mode, cache, src: string; output: var string): bool =
  ## One `nimony c` into a freshly wiped `cache`. `NIMONY_VFS_STATS` makes
  ## every process of the build print its own store line, which is how the
  ## caller can tell an engaged store from a mode that was silently ignored.
  removeDir cache
  let nimony = toolchainDir / "nimony".addFileExt(ExeExt)
  let cmd = nimony.quoteShell & " c --silentMake --vfs:" & mode &
            " --nimcache:" & cache.quoteShell & " " & src.quoteShell
  putEnv("NIMONY_VFS_STATS", "1")
  let (outp, ec) = execCmdEx(cmd)
  delEnv("NIMONY_VFS_STATS")
  output = outp
  result = ec == 0
  if not result:
    echo outp

proc storeLineTotals(output: string; field: string): int =
  ## Sum one `[store] … <field>=<n>` counter across every process of a build.
  result = 0
  for line in output.splitLines:
    if not line.startsWith("[store]"): continue
    for part in line.split(' '):
      let eq = part.find('=')
      if eq > 0 and part[0 ..< eq] == field:
        try: result += parseInt(part[eq+1 .. ^1])
        except ValueError: discard

proc modeCase(src: string) =
  echo "--vfs:disk and --vfs:verify agree on ", src
  let nimony = toolchainDir / "nimony".addFileExt(ExeExt)
  if not fileExists(nimony):
    fail "no " & nimony & "; run `hastur build nimony` first"
    return
  if not fileExists(src):
    fail "missing fixture " & src
    return
  let cache = cacheRoot / "vfsmodes"

  var diskOut = ""
  if not compileUnder("disk", cache, src, diskOut):
    fail "the --vfs:disk build failed"
    return
  let disk = artifactSnapshot(cache)
  if disk.len == 0:
    fail "the --vfs:disk build produced no .nif artifacts"
    return

  var verifyOut = ""
  if not compileUnder("verify", cache, src, verifyOut):
    fail "the --vfs:verify build failed"
    return
  let verify = artifactSnapshot(cache)

  ok "--vfs:verify completed with no mismatch"
  let checks = storeLineTotals(verifyOut, "verify")
  let mismatches = storeLineTotals(verifyOut, "mismatches")
  if checks == 0:
    fail "the store answered no read from memory; --vfs:verify proved nothing"
  else:
    ok "the store was engaged (" & $checks & " reads compared against the disk)"
  if mismatches != 0:
    fail $mismatches & " verify mismatch(es) reported"

  var missing: seq[string] = @[]
  var extra: seq[string] = @[]
  var differing: seq[string] = @[]
  for name, bytes in disk:
    if name notin verify: missing.add name
    elif verify[name] != bytes: differing.add name
  for name in verify.keys:
    if name notin disk: extra.add name
  sort missing
  sort extra
  sort differing
  if missing.len > 0: fail "only in the disk build: " & missing[0 ..< min(3, missing.len)].join(", ")
  if extra.len > 0: fail "only in the verify build: " & extra[0 ..< min(3, extra.len)].join(", ")
  if differing.len > 0:
    fail $differing.len & " artifact(s) differ, first: " & differing[0 ..< min(3, differing.len)].join(", ")
  if missing.len == 0 and extra.len == 0 and differing.len == 0:
    ok "both modes left the same " & $disk.len & " .nif artifacts, byte for byte"
  removeDir cache

bifCase()
vfsCase()
modeCase("tests/nimony/consteval/tmyops.nim")
modeCase("tests/incremental/sample.nim")

if failures > 0:
  echo "nifcache: ", failures, " failure(s)"
  quit 1
echo "nifcache: all checks passed"
