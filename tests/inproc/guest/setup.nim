## Custom runner for phase B4 step 1 (`JIT_IMPL.md`): the out-of-process
## `nimrun` guest.
##
## The claim under test is the one `nimony dev` stands on, and nothing else:
## **one host process can run several programs, and each of them produces
## exactly what a separate `nimony r` produces.**
##
## Why that is not free. `engine.runWholeProgram` maps the arena in the
## caller's process and calls the guest's `main` on a thread of its own.
## `nifasm/hostrun.guestExit` cannot return into a guest frame, so the thread
## that calls `exit` — which is EVERY guest, because `lengcgen.genMainProc`
## ends in `cExit` — parks forever, and the arena it is parked in can never be
## released (`notes/b1-nimony.md`, "Not done": *"a `nimony dev` (B4) running
## many programs in one process would have to, and cannot"*). Measured on this
## host: fifty in-process runs leave fifty-one threads and 13.6 GB of mapped
## address space; fifty through `nimrun` leave one thread and no growth
## (`notes/b4.md`).
##
## Shape of the run:
##
## 1. Two small programs, each built and run once by `bin/nimony r` into its
##    own nimcache. That is the REFERENCE — one program, one compiler process,
##    the path every number in `bench/` was taken with — and it is also what
##    produces the `.asm.nif` modules the loader will read.
## 2. `driver.nim`, linked against `src/nimony/engine`, runs both programs
##    through `runWholeProgramOutOfProcess` in ONE process, each with its
##    stdout `dup2`'d onto a file.
## 3. Compare: the bytes, the exit statuses, and the host's own thread count
##    before and after.
##
## Why two DIFFERENT programs rather than one twice: a second run in the same
## process is where stale state shows up, and two different module sets are
## what make the loader's `openFileSession` and blob cache do different work
## each time.
##
## `tests/inproc/` deliberately holds no `.nim` file of its own so that the
## tree walk descends into it and finds this runner (`walk.collectTests`).

import std / [os, strutils, osproc, syncio]
import "../../../src/hastur/context"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")
let testDir = if arg("dir").len > 0: arg("dir") else: "tests" / "inproc" / "guest"

var failures = 0

proc fail(msg: string) =
  echo "[inproc/guest] FAIL: ", msg
  inc failures

proc ok(msg: string) =
  echo "[inproc/guest] ok: ", msg

let nimony = toolExe("nimony")
let nimrun = toolExe("nimrun")

if not fileExists(nimony):
  echo "[inproc/guest] no `nimony` in ", toolchainDir, "; nothing to test"
  quit 1
if not fileExists(nimrun) or
   not fileExists(toolExe("arkham")) or not fileExists(toolExe("nifasm")):
  # The same vacuous-rather-than-failing arrangement `tests/nimony_r` and
  # `tests/nativecg` have: without the sibling `../nativenif` at build time
  # there is no arkham, no nifasm, no `-d:nimonyEngine` and no `nimrun`, so
  # there is no second way of running a program to compare against the first.
  echo "[inproc/guest] no nimrun/arkham/nifasm in ", toolchainDir,
       " (no ../nativenif at build time); nothing to test"
  quit 0

let scratch = nimcacheDir / "inproc_guest"
removeDir scratch
createDir scratch

const
  OneSrc = """
import std/syncio
echo "guest one speaking"
echo "and a second line"
"""
  TwoSrc = """
import std/syncio
proc twice(x: int): int = x * 2
echo "guest two speaking: ", twice(21)
quit(7)
"""

type
  Built = object
    ## One program after the reference run: where its modules are, what the
    ## main module is called, and what a plain `nimony r` printed and returned.
    backendDir, mainModule, blobDir: string
    refOut: string
    refStatus: int

proc runEngineSuffix(errText: string): string =
  ## The main module's suffix, off the `[run-engine] <suffix> …` line
  ## `--verbose` writes to stderr. It is the one place the compiler already
  ## says which module the image was built from, so the runner reads it rather
  ## than recomputing `modnames.moduleSuffix`.
  for line in errText.splitLines:
    if line.startsWith("[run-engine] "):
      let rest = line["[run-engine] ".len .. ^1]
      let sp = rest.find(' ')
      return (if sp < 0: rest else: rest[0 ..< sp])
  result = ""

proc reference(name, src: string): Built =
  ## Build and run one program the ordinary way. stdout and stderr go to
  ## separate files on purpose: the comparison is about the PROGRAM's stdout,
  ## and `--verbose`'s timing line is the compiler's stderr.
  result = Built(backendDir: "", mainModule: "", blobDir: "", refOut: "",
                 refStatus: -1)
  let dir = scratch / name
  createDir dir
  let file = dir / name & ".nim"
  writeFile(file, src)
  let cache = dir / "nc"
  let outFile = dir / "ref.out"
  let errFile = dir / "ref.err"
  let cmd = quoteShell(nimony) & " r --silentMake --verbose --nimcache:" &
    quoteShell(cache) & " " & quoteShell(file) &
    " > " & quoteShell(outFile) & " 2> " & quoteShell(errFile)
  result.refStatus = execShellCmd(cmd)
  if not fileExists(outFile) or not fileExists(errFile):
    fail name & ": `nimony r` produced no output files"
    return
  result.refOut = readFile(outFile)
  let suffix = runEngineSuffix(readFile(errFile))
  if suffix.len == 0:
    fail name & ": `nimony r --verbose` printed no [run-engine] line:\n" &
      readFile(errFile).strip
    return
  result.mainModule = suffix
  result.backendDir = cache / (suffix & ".n")
  result.blobDir = cache / "blobcache"
  if not fileExists(result.backendDir / suffix & ".asm.nif"):
    fail name & ": no " & suffix & ".asm.nif under " & result.backendDir
    return
  ok name & ": `nimony r` -> status " & $result.refStatus & ", " &
    $result.refOut.len & " bytes of stdout (module " & suffix & ")"

let one = reference("one", OneSrc)
let two = reference("two", TwoSrc)
if failures > 0:
  quit "FAILURE: " & $failures & " inproc/guest test(s) failed"

# ---- the driver: both programs, one process --------------------------------

# `src/nimony/engine.nim` links arkham and nifasm out of the sibling checkout,
# so the driver needs the three flags `hastur/builders.engineFlags()` passes —
# spelled out here for the same reason `tests/inproc/hexer` spells out hexer's:
# `nim c` reads a config for the PROJECT's directory chain, and this project is
# not under `src/`. `NIMONY_NATIVENIF` picks the checkout exactly as
# `hastur/deps.NativenifDir` does. `--path:src/lib` is the fourth: `src/nimony/
# nim.cfg` puts it there for nimsem, and arkham's unqualified `import nifcore`
# resolves through it — the same flag `tests/inproc/hexer` passes for the same
# reason.
let nativenif = block:
  let fromEnv = getEnv("NIMONY_NATIVENIF")
  if fromEnv.len > 0: fromEnv else: ".." / "nativenif"

# The driver goes into a `bin/` of its own with a copy of `nimrun` beside it.
# That is not a test artifice: `engine.runWholeProgramOutOfProcess` resolves the
# loader with `tooldirs.findTool`, which looks NEXT TO THE RUNNING EXECUTABLE
# and nowhere else — no cwd, no `PATH` (the `small items` fix in JIT_IMPL.md).
# So any host that embeds the engine ships `nimrun` in its own toolchain
# directory, and this is that arrangement in miniature.
let driverDir = scratch / "bin"
createDir driverDir
copyFile(nimrun, driverDir / "nimrun".addFileExt(ExeExt))
setFilePermissions(driverDir / "nimrun".addFileExt(ExeExt),
                   getFilePermissions(nimrun))
let driverBin = driverDir / "driver".addFileExt(ExeExt)
let driverCmd = "nim c --hints:off --experimental:strictDefs" &
  " --warningAsError:ProveInit:off --warningAsError:Uninit:off" &
  " -d:nimonyEngine --undef:nimPreviewSlimSystem" &
  " --path:" & quoteShell("src") &
  " --path:" & quoteShell("src" / "lib") &
  " --path:" & quoteShell(nativenif / "src") &
  " --path:" & quoteShell(nativenif / "src" / "common") &
  " --nimcache:" & quoteShell(scratch / "drivercache") &
  " -o:" & quoteShell(driverBin) & " " & quoteShell(testDir / "driver.nim")
let (buildOut, buildCode) = execCmdEx(driverCmd)
if buildCode != 0:
  fail "compiling the driver failed:\n" & driverCmd & "\n" & buildOut
  quit "FAILURE: " & $failures & " inproc/guest test(s) failed"

let resultFile = scratch / "report.txt"
let outOne = scratch / "one.driver.out"
let outTwo = scratch / "two.driver.out"
var driverArgs = ""
for a in [resultFile,
          one.backendDir, one.mainModule, one.blobDir, outOne,
          two.backendDir, two.mainModule, two.blobDir, outTwo]:
  driverArgs.add " " & quoteShell(a)
let (driverOut, driverCode) = execCmdEx(quoteShell(driverBin) & driverArgs)
if driverCode != 0:
  fail "the driver exited " & $driverCode & ":\n" & driverOut
if not fileExists(resultFile):
  fail "the driver wrote no report; it did not survive both runs"
  quit "FAILURE: " & $failures & " inproc/guest test(s) failed"

# ---- the verdict ------------------------------------------------------------

let report = readFile(resultFile).splitLines
if report.len < 4 or report[3] != "alive":
  fail "the driver's report is short or does not end in `alive`:\n" &
    readFile(resultFile)
  quit "FAILURE: " & $failures & " inproc/guest test(s) failed"
ok "one host process ran both programs and is still running"

proc checkOne(idx: int; name: string; b: Built; produced: string) =
  let f = report[idx].split(' ', 2)
  if f.len < 2:
    fail name & ": malformed report line `" & report[idx] & "`"
    return
  if f[0] != "ran":
    fail name & ": the loader refused it: " & (if f.len > 2: f[2] else: "")
    return
  var status = -1
  try:
    status = parseInt(f[1])
  except ValueError:
    fail name & ": malformed status `" & f[1] & "`"
    return
  if status != b.refStatus:
    fail name & ": exit status " & $status & " out of process, " &
      $b.refStatus & " from `nimony r`"
  else:
    ok name & ": exit status " & $status & " both ways"
  if not fileExists(produced):
    fail name & ": the driver wrote no stdout file"
    return
  let got = readFile(produced)
  if got == b.refOut:
    ok name & ": stdout byte-identical to `nimony r` (" & $got.len & " bytes)"
  else:
    var at = 0
    while at < min(got.len, b.refOut.len) and got[at] == b.refOut[at]: inc at
    fail name & ": stdout differs at byte " & $at & "\n    nimony r: " &
      b.refOut.strip & "\n    nimrun:   " & got.strip

checkOne(0, "program one", one, outOne)
checkOne(1, "program two", two, outTwo)

# The reason the phase exists, as a number. `-1` is "this host cannot say", and
# is not a failure: the byte and status checks above are the gate, and the
# thread count is the evidence for WHY it needs a process boundary.
let threads = report[2].split(' ')
if threads.len == 3 and threads[1] != "-1":
  if threads[1] == threads[2]:
    ok "the host still has " & threads[2] &
       " thread(s) after both runs (in-process, each `exit` parks one forever)"
  else:
    fail "the host grew threads across the runs: " & threads[1] &
      " -> " & threads[2]

# Two different programs really were run, not one twice.
if one.refOut == two.refOut:
  fail "the two reference programs printed the same thing; the second run " &
    "is not distinguishable from the first"

if failures > 0:
  quit "FAILURE: " & $failures & " inproc/guest test(s) failed"
echo "[inproc/guest] all checks passed"
