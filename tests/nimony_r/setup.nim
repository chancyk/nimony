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
checkCompilerItself()

removeDir work

if failures > 0:
  echo "nimony_r: ", failures, " failure(s)"
  quit 1
echo "nimony_r: all checks passed"
