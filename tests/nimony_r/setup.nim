## Custom runner for `nimony r` — build with the native backend and run the
## program out of the compiler's own memory (`src/nimony/engine.nim`'s
## `runWholeProgram`, JIT_IMPL.md phase B1).
##
## The question this directory answers is not "does the program produce the
## right value" — `tests/nimony` already asks that of the same programs through
## `nimony n`. It is the narrower one that only a second way of running them
## can ask: **does running from memory produce exactly what running the linked
## executable produces**, for stdout, for stderr and for the exit status. So
## almost every check below is differential: compile once, run twice, compare.
##
## The cases that are NOT differential are the ones about the command rather
## than about the program:
##
## * no executable is written unless `--out` asks for one (that saving is the
##   phase's whole point, and a `nimony r` that quietly linked anyway would
##   still pass every output comparison);
## * `--out` does write one, and it runs;
## * the compiler itself — 130 modules, the largest program in the repository —
##   runs from memory and prints its version.
##
## `hastur.mode = skip` for the reason `tests/nativecg` has it: without a
## sibling `../nativenif` there is no arkham, no nifasm and nothing here to
## test. Run it explicitly with `bin/hastur test tests/nimony_r`.

import std / [os, osproc, strutils]
import "../../src/hastur/kit"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")

let here = currentSourcePath().parentDir
let repo = here.parentDir.parentDir
let nimony = toolchainDir / "nimony".addFileExt(ExeExt)
let work = getTempDir() / "nimony_r" / $getCurrentProcessId()

var failures = 0

proc fail(what: string) =
  inc failures
  echo "  FAIL ", what

proc ok(what: string) =
  echo "  ok   ", what

type
  Run = object
    ## One execution of a program, however it was run. `output` is stdout and
    ## stderr together, because the guest's own buffering decides how they
    ## interleave and the comparison has to see the same stream both ways.
    output: string
    code: int

proc runCmd(cmd: string): Run =
  ## `execCmdEx` merges stderr into stdout and gives the real exit status,
  ## which is exactly the pair every check here compares.
  let (o, c) = execCmdEx(cmd)
  result = Run(output: o, code: c)

proc nimonyR(src: string; cache: string; args = ""; extra = ""): Run =
  runCmd(nimony.quoteShell & " r --silentMake " & extra &
         " --nimcache:" & cache.quoteShell & " " & src.quoteShell &
         (if args.len > 0: " " & args else: ""))

proc runEngineLine(r: Run): string =
  ## The `[run-engine] …` line `--verbose` writes to stderr, or "" if there is
  ## none. `execCmdEx` merged the streams, so it has to be found rather than
  ## assumed to be first: a program that prints is free to print before it.
  for line in r.output.splitLines:
    if line.startsWith("[run-engine] "): return line
  result = ""

proc field(line, key: string): string =
  ## `key=value` out of the timing line, "" when absent. The line is a flat
  ## space-separated list on purpose, so that a test can read one number out of
  ## it without a parser and without pinning the order of the rest.
  let at = line.find(" " & key & "=")
  if at < 0: return ""
  var i = at + key.len + 2
  while i < line.len and line[i] != ' ':
    result.add line[i]
    inc i

proc intField(line, key: string): int =
  ## `field` as a number; -1 when the field is missing or is not one. Digits by
  ## hand: a malformed line must be a FAILED check, not an exception that ends
  ## the runner before the later cases run.
  let s = field(line, key)
  if s.len == 0: return -1
  result = 0
  for ch in s:
    if ch notin {'0'..'9'}: return -1
    result = result * 10 + (ord(ch) - ord('0'))

proc msField(line, key: string): float =
  ## `key=123.45ms` as a float; -1.0 when absent or malformed.
  let s = field(line, key)
  if s.len < 3 or not s.endsWith("ms"): return -1.0
  try:
    result = parseFloat(s[0 ..< s.len - 2])
  except ValueError:
    result = -1.0

proc nimonyN(src: string; cache: string): Run =
  runCmd(nimony.quoteShell & " n --silentMake --nimcache:" & cache.quoteShell &
         " " & src.quoteShell)

proc exeIn(cache: string): string =
  ## The one executable a `nimony n` of a single-file program leaves in its
  ## backend directory. Found rather than derived: the name is the source's
  ## basename and the directory is a module-suffix hash, and a test that
  ## recomputed both would be testing `deps.exeFile` instead of `nimony r`.
  result = ""
  for kind, dir in walkDir(cache):
    if kind != pcDir or not dir.endsWith(".n"): continue
    for k2, f in walkDir(dir):
      if k2 == pcFile and f.splitFile.ext.len == 0:
        return f

proc writeSrc(path, content: string) =
  createDir path.parentDir
  writeFile(path, content)

# ── the differential check ───────────────────────────────────────────────────

proc sameRun(a, b: Run): bool =
  ## The whole comparison, in one place, so the self-test below exercises the
  ## very proc every case uses rather than a copy of its reasoning.
  a.output == b.output and a.code == b.code

proc differs(name, src, cache: string; args = ""): bool =
  ## Compile once with `nimony n`, run the linked executable, then run the same
  ## program through `nimony r`, and compare output and status. Returns true on
  ## a difference, so the caller can count it.
  let build = nimonyN(src, cache)
  if build.code != 0:
    fail name & ": `nimony n` failed\n" & build.output.strip
    return true
  let exe = exeIn(cache)
  if exe.len == 0:
    fail name & ": `nimony n` left no executable in " & cache
    return true
  let viaExe = runCmd(exe.quoteShell & (if args.len > 0: " " & args else: ""))
  let viaMem = nimonyR(src, cache, args)
  result = false
  if sameRun(viaExe, viaMem):
    ok name & " (both ways: " & $viaExe.code & ", " &
       $viaExe.output.strip.splitLines.len & " line(s))"
    return false
  if viaExe.output != viaMem.output:
    fail name & ": output differs\n    exe: " & viaExe.output.strip &
         "\n    mem: " & viaMem.output.strip
    result = true
  if viaExe.code != viaMem.code:
    fail name & ": exit status differs (exe " & $viaExe.code &
         ", mem " & $viaMem.code & ")"
    result = true

proc selfTest() =
  ## What proves the comparison has teeth: runs that really do differ must be
  ## reported as differing, and identical ones must not. Without it a
  ## `sameRun` that compared nothing would make every case below pass in
  ## silence — the same reason `tests/ctfe_diff` opens with
  ## `ctfeDiffSelfTest`.
  let a = Run(output: "x\n", code: 0)
  if not sameRun(a, Run(output: "x\n", code: 0)):
    fail "self-test: identical runs compared unequal"
  if sameRun(a, Run(output: "y\n", code: 0)):
    fail "self-test: differing output compared equal"
  if sameRun(a, Run(output: "x\n", code: 3)):
    fail "self-test: differing status compared equal"
  ok "self-test: the comparison sees output and status"

# ── the programs ─────────────────────────────────────────────────────────────

const
  HelloSrc = """
import std/syncio
echo "hello from nimony r"
"""
  QuitSrc = """
import std/syncio
echo "before the quit"
quit(3)
"""
  ArgvSrc = """
import std / [syncio, cmdline]
echo "argc=", paramCount()
for i in 1 .. paramCount():
  echo "arg", i, "=", paramStr(i)
"""
  StreamsSrc = """
import std/syncio
echo "out1"
stderr.write "err1\n"
echo "out2"
stderr.write "err2\n"
"""
  PanicSrc = """
import std / [syncio]

type TA = array[0..3, int]

proc main(a: TA) =
  for i in 0..4:
    echo a[i]
    flushFile(stdout)

main([1, 2, 3, 4])
"""

  # Five programs from the recorded native regression set
  # (`hastur/nativelist.nim`'s `NativeTestDirs`), i.e. programs `nimony n` is
  # already known to compile correctly on this host. What is new here is only
  # the second way of running them.
  Corpus = ["tests/nimony/arc/tbasics.nim",
            "tests/nimony/arc/tconcat.nim",
            "tests/nimony/arc/tcontrolflow.nim",
            "tests/nimony/arc/tdestructor_order.nim",
            "tests/nimony/arc/trefobjconstr.nim"]

proc checkHello() =
  let src = work / "hello" / "hello.nim"
  writeSrc src, HelloSrc
  let r = nimonyR(src, work / "hello" / "nc")
  if r.code != 0:
    fail "hello: exit " & $r.code & "\n" & r.output.strip
  elif "hello from nimony r" notin r.output:
    fail "hello: did not print\n" & r.output.strip
  else:
    ok "hello prints and exits 0"

proc checkQuit() =
  let src = work / "quit" / "quit.nim"
  writeSrc src, QuitSrc
  let cache = work / "quit" / "nc"
  let r = nimonyR(src, cache)
  if r.code != 3:
    fail "quit(3): exit " & $r.code & " (want 3)\n" & r.output.strip
  else:
    ok "quit(3) exits 3 through `nimony r`"
  discard differs("quit(3) exe vs mem", src, cache)

proc checkArgv() =
  let src = work / "argv" / "argv.nim"
  writeSrc src, ArgvSrc
  let r = nimonyR(src, work / "argv" / "nc", "a b")
  # `paramStr(0)` is the program's own name and is deliberately NOT compared:
  # the linked binary sees its path and the in-memory run sees the project
  # file, the same difference `nim r` has.
  if r.code != 0 or "argc=2" notin r.output or
     "arg1=a" notin r.output or "arg2=b" notin r.output:
    fail "argv: `nimony r prog.nim a b` gave\n" & r.output.strip
  else:
    ok "argv reaches the program"

proc checkStreams() =
  let src = work / "streams" / "streams.nim"
  writeSrc src, StreamsSrc
  discard differs("stdout/stderr interleaving", src, work / "streams" / "nc")

proc checkPanic() =
  let src = work / "panic" / "panic.nim"
  writeSrc src, PanicSrc
  let cache = work / "panic" / "nc"
  # An unhandled runtime error: nimony has no "unhandled exception" at the top
  # level (`.raises` is checked), so the shape this asks about is a `panic` —
  # a bound check that fails, writes its own message to fd 2 and ends the
  # program. Both the message and the status must match the linked binary's.
  let r = nimonyR(src, cache)
  if r.code == 0:
    fail "panic: exited 0"
  elif "index out of bounds" notin r.output:
    fail "panic: no diagnostic\n" & r.output.strip
  else:
    ok "an unhandled runtime error exits non-zero with its message"
  discard differs("panic exe vs mem", src, cache)

proc checkCorpus() =
  for i in 0 ..< Corpus.len:
    let src = repo / Corpus[i]
    if not fileExists(src):
      fail "corpus: missing " & Corpus[i]
      continue
    discard differs(Corpus[i].extractFilename, src,
                    work / "corpus" / $i)

proc checkNoExecutable() =
  ## The saving is the phase: a `nimony r` that still linked would pass every
  ## comparison above and be worth nothing. So look at what the run left on
  ## disk — every module's `.asm.nif`, and no file without an extension.
  let src = work / "noexe" / "noexe.nim"
  writeSrc src, HelloSrc
  let cache = work / "noexe" / "nc"
  let r = nimonyR(src, cache)
  if r.code != 0:
    fail "no-executable: the run failed\n" & r.output.strip
    return
  var asmModules = 0
  var stray = ""
  for kind, dir in walkDir(cache):
    if kind != pcDir or not dir.endsWith(".n"): continue
    for k2, f in walkDir(dir):
      if k2 != pcFile: continue
      if f.endsWith(".asm.nif"): inc asmModules
      elif f.splitFile.ext.len == 0: stray = f
  if asmModules == 0:
    fail "no-executable: the build produced no `.asm.nif` at all"
  elif stray.len > 0:
    fail "no-executable: `nimony r` linked one anyway: " & stray
  else:
    ok "no executable written (" & $asmModules & " `.asm.nif` modules)"

proc checkOutWritesExecutable() =
  ## `--out` is the one way to ask `nimony r` for the file as well, and it must
  ## be a working one — otherwise the flag is a slower run with a broken
  ## by-product.
  let src = work / "without" / "without.nim"
  writeSrc src, HelloSrc
  let outFile = work / "without" / "bin" / "hello".addFileExt(ExeExt)
  let r = nimonyR(src, work / "without" / "nc", "", "--out:" & outFile.quoteShell)
  if r.code != 0 or "hello from nimony r" notin r.output:
    fail "--out: the run itself failed\n" & r.output.strip
  elif not fileExists(outFile):
    fail "--out: no executable at " & outFile
  else:
    let viaExe = runCmd(outFile.quoteShell)
    if viaExe.code != 0 or viaExe.output != r.output:
      fail "--out: the written executable disagrees with the in-memory run\n" &
           "    exe: " & viaExe.output.strip & "\n    mem: " & r.output.strip
    else:
      ok "--out writes an executable that agrees with the in-memory run"

proc checkCrossCompileRefused() =
  ## `nimony r` runs the program in the compiler's own process, so a `--cpu` /
  ## `--os` naming another machine is not something it can do -- and the honest
  ## answer is a diagnostic naming the command that can, not a build followed
  ## by a crash inside somebody else's instruction set.
  let src = work / "cross" / "cross.nim"
  writeSrc src, HelloSrc
  let r = nimonyR(src, work / "cross" / "nc", "",
                  "--cpu:amd64 --os:linux")
  if r.code == 0:
    fail "cross: `nimony r --cpu:amd64 --os:linux` succeeded\n" & r.output.strip
  elif "cross compile" notin r.output:
    fail "cross: refused without saying why\n" & r.output.strip
  else:
    ok "a cross compile is refused, not attempted"

proc checkBlobCache() =
  ## The per-symbol code cache (JIT_IMPL.md B3, nativenif's `blobcache.nim`)
  ## across an edit, which is the shape the dev loop actually has.
  ##
  ## Three things, and the first two are what make the third meaningful:
  ##
  ## 1. **the edit is not lost.** The same source, edited in its body, run
  ##    twice: the second run must print the NEW text. A cache that replayed a
  ##    stale fragment would print the old one, and that is the failure mode
  ##    worth more than any timing.
  ## 2. **the cache filled and was then used.** The first run into a fresh
  ##    nimcache records fragments and hits nothing; the second replays them.
  ##    Asserted on nifasm's own counters, which `--verbose` puts on the
  ##    `[run-engine]` line, and on the directory being there with files in it.
  ## 3. **and it was cheaper.** `emitRoots` is 96.7 % of a cold link, so it is
  ##    the number a cache has to move; `assemble` is compared too. Both are
  ##    wall times on a machine a test suite does not own, so the assertion is
  ##    "not slower", not a ratio -- the ratio is the benchmark's job
  ##    (`bench/devloop_bench.sh`), and a test that demanded one would fail on
  ##    a loaded CI box while a cache that had stopped working entirely still
  ##    shows up in `hits`.
  let dir = work / "blobcache"
  let src = dir / "edited.nim"
  let cache = dir / "nc"
  writeSrc src, HelloSrc

  let cold = nimonyR(src, cache, "", "--verbose")
  let coldLine = runEngineLine(cold)
  if cold.code != 0 or coldLine.len == 0:
    fail "blobcache: the cold run failed or printed no timing line\n" &
         cold.output.strip
    return
  if field(coldLine, "blobcache") != "on":
    fail "blobcache: the cache is off by default (" & coldLine & ")"
    return
  let coldRecorded = intField(coldLine, "recorded")
  if intField(coldLine, "hits") != 0 or coldRecorded <= 0:
    fail "blobcache: a cold run should record fragments and hit none: " & coldLine
  else:
    ok "a cold `nimony r` records " & $coldRecorded & " fragments"

  let store = cache / "blobcache"
  var blobs = 0
  if dirExists(store):
    for kind, f in walkDir(store):
      if kind == pcFile and f.endsWith(".blob.nif"): inc blobs
  if blobs == 0:
    fail "blobcache: nothing under " & store
  else:
    ok "the cache directory holds " & $blobs & " module blob(s)"

  # The edit: one more statement in the body, so the program's OUTPUT changes.
  writeSrc src, HelloSrc & "echo \"and again, after the edit\"\n"
  let warm = nimonyR(src, cache, "", "--verbose")
  let warmLine = runEngineLine(warm)
  if warm.code != 0 or warmLine.len == 0:
    fail "blobcache: the second run failed\n" & warm.output.strip
    return
  if "and again, after the edit" notin warm.output:
    fail "blobcache: the edit did not reach the program\n" & warm.output.strip
  elif "hello from nimony r" notin warm.output:
    fail "blobcache: the unedited half of the program went missing\n" &
         warm.output.strip
  else:
    ok "an edited body runs its new code on the second `nimony r`"

  let warmHits = intField(warmLine, "hits")
  if warmHits <= 0:
    fail "blobcache: the second run replayed nothing: " & warmLine
  else:
    ok "the second run replays " & $warmHits & " cached fragment(s)"

  let coldRoots = msField(coldLine, "emitRoots")
  let warmRoots = msField(warmLine, "emitRoots")
  let coldAsm = msField(coldLine, "assemble")
  let warmAsm = msField(warmLine, "assemble")
  if coldRoots < 0.0 or warmRoots < 0.0 or coldAsm < 0.0 or warmAsm < 0.0:
    fail "blobcache: the timing line is missing a number\n    " & coldLine &
         "\n    " & warmLine
  elif warmRoots > coldRoots or warmAsm > coldAsm:
    fail "blobcache: the warm assemble was not faster (emitRoots " &
         $coldRoots & " -> " & $warmRoots & " ms, assemble " &
         $coldAsm & " -> " & $warmAsm & " ms)"
  else:
    ok "the warm assemble is faster (emitRoots " & $coldRoots & " -> " &
       $warmRoots & " ms)"

  # `--no-blobcache` is the escape hatch, and it must actually take the hatch:
  # it must report the cache off and still print exactly what the cached run
  # printed. The output comparison is between two runs WITHOUT `--verbose`, so
  # that it compares the program's output rather than the compiler's stderr.
  let offVerbose = nimonyR(src, cache, "", "--verbose --no-blobcache")
  let offLine = runEngineLine(offVerbose)
  if offVerbose.code != 0 or offLine.len == 0:
    fail "blobcache: `--no-blobcache` failed\n" & offVerbose.output.strip
  elif field(offLine, "blobcache") != "off":
    fail "blobcache: `--no-blobcache` left the cache on: " & offLine
  else:
    let plain = nimonyR(src, cache)
    let off = nimonyR(src, cache, "", "--no-blobcache")
    if not sameRun(plain, off):
      fail "blobcache: `--no-blobcache` changed the run\n    cached: " &
           plain.output.strip & "\n    plain:  " & off.output.strip
    else:
      ok "`--no-blobcache` turns the cache off and the program is unchanged"

proc nifasmProfiled(body: proc (): Run {.closure.}): Run =
  ## Run `body` with `NIFASM_PROFILE=1` in the environment, so a SPAWNED nifasm
  ## -- the `link` node of `nimony n`, which is the only way to see that path's
  ## cache counters -- prints its per-stage table on stderr. `putEnv` rather
  ## than a shell prefix: `execCmdEx` does not go through a shell everywhere.
  putEnv("NIFASM_PROFILE", "1")
  result = body()
  delEnv("NIFASM_PROFILE")

proc profileRow(output, row: string): int =
  ## The `n` column of one row of nifasm's `[nifasm profile]` table, or -1.
  ## The table is `  <name> <ms> <count> <n>`, so the number wanted is the last
  ## field of the line whose first field is `row`.
  result = -1
  for line in output.splitLines:
    let f = line.splitWhitespace
    if f.len == 4 and f[0] == row:
      var v = 0
      for ch in f[3]:
        if ch notin {'0'..'9'}: return -1
        v = v * 10 + (ord(ch) - ord('0'))
      return v

proc checkSharedCacheDir() =
  ## One directory, both native paths, and the same executable either way.
  ##
  ## `nimony n`'s `link` node passes `--blobcache:<nimcache>/blobcache` to
  ## nifasm; `nimony r` hands `AsmSession.useBlobCache` the same string. What
  ## they share is the DIRECTORY, not the fragments: nifasm keys a blob on
  ## target + flags + tool build id + module name, and `nimony r` assembles
  ## with `--dev-single-thread` and no debug info while a linked executable has
  ## threads and debug info -- genuinely different code, and so deliberately
  ## different keys in the one store. Sharing the directory is still what
  ## matters: it is scoped by `--nimcache`, swept by `hastur clean`, and
  ## neither path's entries confuse the other's.
  ##
  ## So: each path warm on its own repeat, in one nimcache, plus the byte
  ## identity that is the whole licence for having a cache at all.
  let dir = work / "shared"
  let src = dir / "shared.nim"
  let cache = dir / "nc"
  writeSrc src, HelloSrc

  let cold = nimonyN(src, cache)
  if cold.code != 0:
    fail "shared cache: `nimony n` failed\n" & cold.output.strip
    return

  # A REAL edit, not a rewrite of the same text: every artifact on the way down
  # is written `OnlyIfChanged`, so re-saving identical bytes re-runs nifler and
  # stops there -- and a second link that never happened cannot be observed to
  # have used the cache.
  let edited = HelloSrc & "echo \"a second line\"\n"
  writeSrc src, edited
  let warm = nifasmProfiled(proc (): Run = nimonyN(src, cache))
  if warm.code != 0:
    fail "shared cache: the second `nimony n` failed\n" & warm.output.strip
    return
  let hits = profileRow(warm.output, "blobHits")
  if hits <= 0:
    fail "shared cache: `nimony n`'s link replayed nothing (blobHits " &
         $hits & ")\n" & warm.output.strip
  else:
    ok "`nimony n`'s link node replays " & $hits & " cached fragment(s)"
  let exe = exeIn(cache)
  if exe.len == 0:
    fail "shared cache: `nimony n` left no executable"
    return
  let cachedBytes = readFile(exe)

  # The same program, the same nimcache, the other path.
  let r = nimonyR(src, cache, "", "--verbose")
  let rLine = runEngineLine(r)
  if r.code != 0 or rLine.len == 0:
    fail "shared cache: the `nimony r` failed\n" & r.output.strip
    return
  let r2 = nimonyR(src, cache, "", "--verbose")
  let r2Line = runEngineLine(r2)
  if r2.code != 0 or intField(r2Line, "hits") <= 0:
    fail "shared cache: `nimony r` did not warm its own half: " & r2Line
  else:
    ok "`nimony r` warms its own half of the same directory (" &
       $intField(r2Line, "hits") & " fragments)"

  # And the licence: a cached link and an uncached one produce the same bytes.
  let plainCache = dir / "nc-nocache"
  let plain = runCmd(nimony.quoteShell & " n --silentMake --no-blobcache" &
                     " --nimcache:" & plainCache.quoteShell & " " & src.quoteShell)
  if plain.code != 0:
    fail "shared cache: `nimony n --no-blobcache` failed\n" & plain.output.strip
    return
  let plainExe = exeIn(plainCache)
  if plainExe.len == 0:
    fail "shared cache: `--no-blobcache` left no executable"
  elif readFile(plainExe) != cachedBytes:
    fail "shared cache: the cached link and the scratch link differ in bytes"
  else:
    ok "a cached link and a scratch link produce byte-identical executables"

proc checkOutOfProcess() =
  ## `--guest:subprocess` (JIT_IMPL.md B4 step 1): the same program run in a
  ## `nimrun` loader process instead of in the compiler's own memory.
  ##
  ## Differential against the IN-PROCESS run rather than against the linked
  ## executable, because the linked executable is already covered above and
  ## this is the narrower question: does moving the guest across a
  ## `posix_spawn` change anything the user can see. It must not — `nimrun`
  ## calls the very proc `nimony r` calls, and descriptors 0, 1 and 2 are
  ## inherited untouched, so the two are one implementation with a process
  ## boundary in it (`src/nimony/guestwire.nim`).
  ##
  ## The four shapes are the four ways a program can end: a plain return, an
  ## explicit `quit(n)`, a runtime panic, and arguments reaching `main`.
  if not fileExists(toolchainDir / "nimrun".addFileExt(ExeExt)):
    fail "out-of-process: no `nimrun` in " & toolchainDir &
         " (`hastur build all` builds it beside `nimony`)"
    return
  let dir = work / "guest"
  proc both(name, src, args: string) =
    let file = dir / name / (name & ".nim")
    writeSrc file, src
    let cache = dir / name / "nc"
    # In-process FIRST, so the second run finds a warm blob cache and the
    # comparison is not accidentally also a comparison of cache states.
    let inproc = nimonyR(file, cache, args)
    let sub = nimonyR(file, cache, args, "--guest:subprocess")
    if sameRun(inproc, sub):
      ok "out-of-process " & name & " (both ways: " & $inproc.code & ", " &
         $inproc.output.strip.splitLines.len & " line(s))"
    else:
      if inproc.output != sub.output:
        fail "out-of-process " & name & ": output differs" &
             "\n    inproc: " & inproc.output.strip &
             "\n    nimrun: " & sub.output.strip
      if inproc.code != sub.code:
        fail "out-of-process " & name & ": exit status differs (inproc " &
             $inproc.code & ", nimrun " & $sub.code & ")"
  both("hello", HelloSrc, "")
  both("quit", QuitSrc, "")
  both("panic", PanicSrc, "")
  both("argv", ArgvSrc, "a b")
  both("streams", StreamsSrc, "")

proc checkCompilerItself() =
  ## The biggest program in the repository, ~130 modules: `nimony r` of the
  ## compiler, printing its version. It is here because everything smaller
  ## fits in one arkham module set that the CTFE engine already exercised;
  ## what only this can break is the whole-image assemble and the 8 MB of
  ## code the arena has to hold.
  let src = repo / "src" / "nimony" / "nimony.nim"
  if not fileExists(src):
    fail "compiler: " & src & " is missing"
    return
  let r = nimonyR(src, work / "self" / "nc", "--version")
  if r.code != 0:
    fail "compiler: `nimony r nimony.nim --version` exited " & $r.code &
         "\n" & r.output.strip
  elif r.output.strip.len == 0 or not r.output[0].isDigit:
    fail "compiler: did not print a version\n" & r.output.strip
  else:
    ok "the compiler itself runs from memory (--version -> " &
       r.output.strip.splitLines[0] & ")"

# ── run ──────────────────────────────────────────────────────────────────────

if not fileExists(nimony):
  echo "nimony_r: no `nimony` in ", toolchainDir, "; nothing to test"
  quit 1

if not fileExists(toolchainDir / "arkham".addFileExt(ExeExt)) or
   not fileExists(toolchainDir / "nifasm".addFileExt(ExeExt)):
  # Without arkham and nifasm there is no native backend at all, so the whole
  # directory is vacuous rather than failing -- the same arrangement
  # `tests/nativecg` and `tests/ctfe_engine` have. They live next to `nimony`
  # exactly when the sibling `../nativenif` checkout was there at build time,
  # which is also when `nimony` itself got `-d:nimonyEngine`.
  echo "nimony_r: no arkham/nifasm in ", toolchainDir,
       " (no ../nativenif at build time); nothing to test"
  quit 0

createDir work
selfTest()
checkHello()
checkQuit()
checkArgv()
checkStreams()
checkPanic()
checkCorpus()
checkNoExecutable()
checkOutWritesExecutable()
checkCrossCompileRefused()
checkBlobCache()
checkOutOfProcess()
checkSharedCacheDir()
checkCompilerItself()

removeDir work

if failures > 0:
  echo "nimony_r: ", failures, " failure(s)"
  quit 1
echo "nimony_r: all checks passed"
