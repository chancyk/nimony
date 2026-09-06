## Custom runner for lengc's buffer-level entry points and its global reset
## (`JIT.md` 6.1, `JIT_IMPL.md` phase A2a).
##
## The runner IS the host-Nim driver: it imports `src/lengc/lengc` and calls
## `runLengc` twice in one process, with `resetLengcGlobals()` in between, on
## two independently compiled modules. The question it answers is whether one
## process can do what two processes do, byte for byte — so every generated `.c`
## is compared against the output of a separate `bin/lengc` run on the same
## arguments. A third section drives the buffer overload
## (`nifmodules.parseFromBuf` -> `loadFromBuf` -> `codegen.generateCode`) and
## asserts it produces the same translation unit without touching a file.
##
## Needs a built `bin/nimony` and `bin/lengc` (the tree walk's
## `tests/setup.hastur` provides them).

import std / [os, strutils, osproc]
import "../../../src/hastur/context"
import "../../../src/lengc/lengc"
import "../../../src/lengc/codegen"
import "../../../src/lengc/nifmodules"
import "../../../src/lengc/noptions"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")

var failures = 0

template expect(cond: bool; msg: string) =
  if not cond:
    inc failures
    echo "[inproc/lengc] FAIL: ", msg

proc bail(msg: string) =
  inc failures
  echo "[inproc/lengc] FAIL: ", msg

# --- fixtures --------------------------------------------------------------
#
# Two independent programs, each compiled on its own so that each ends up with
# a backend directory of its own whose main `.c.nif` is named after it. That is
# what makes the two lengc invocations below nameable without guessing at the
# mangled module suffixes of the stdlib modules beside them.

const
  SourceA = """
import std/syncio

proc twice(x: int): int = x + x

proc emit(n: int) =
  echo "a ", twice(n)

emit(21)
"""
  SourceB = """
import std/syncio

type Point = object
  x, y: int

proc manhattan(p: Point): int =
  result = p.x + p.y
  if result < 0: result = -result

proc show(p: Point) =
  echo "b ", manhattan(p)

show(Point(x: 3, y: -4))
"""

let scratch = absolutePath(nimcacheDir / "inproc_lengc")
removeDir scratch
createDir scratch

let srcDir = scratch / "src"
createDir srcDir
writeFile(srcDir / "inproc_a.nim", SourceA)
writeFile(srcDir / "inproc_b.nim", SourceB)

let nimony = toolchainDir / "nimony".addFileExt(ExeExt)
let lengcExe = toolchainDir / "lengc".addFileExt(ExeExt)

proc buildFixture(name: string): string =
  ## Compile one fixture and return its backend directory, i.e. the directory
  ## holding `<suffix>.c.nif` for it and for everything it imported.
  result = ""
  let cache = scratch / ("nc_" & name)
  let cmd = quoteShell(nimony) & " c --silentMake --nimcache:" &
            quoteShell(cache) & " " & quoteShell(srcDir / (name & ".nim"))
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    bail "compiling " & name & " failed:\n" & output
    return
  # The backend directory is the one subdirectory of the cache; its own name is
  # the main module's suffix, so `<dir>/<basename>.c.nif` is the main input.
  for x in walkDir(cache):
    if x.kind == pcDir and fileExists(x.path / (x.path.splitPath.tail & ".c.nif")):
      return x.path
  bail "no backend directory with a main .c.nif under " & cache

let dirA = buildFixture("inproc_a")
let dirB = buildFixture("inproc_b")

if failures > 0:
  quit "FAILURE: " & $failures & " inproc/lengc test(s) failed"

proc mainInput(backendDir: string): string =
  backendDir / (backendDir.splitPath.tail & ".c.nif")

proc mainOutput(backendDir: string): string =
  backendDir / (backendDir.splitPath.tail & ".c")

let inputA = mainInput(dirA)
let inputB = mainInput(dirB)

proc lengcArgs(backendDir: string): seq[string] =
  ## Exactly the shape `deps.nim` emits for a main module's lengc node:
  ## `lengc c --compileOnly --bits:64 --nimcache:<backendDir> --isMain <input>`.
  result = @["c", "--compileOnly", "--bits:64",
             "--nimcache:" & backendDir, "--isMain", mainInput(backendDir)]

proc takeOutput(backendDir, saveAs: string) =
  ## Move the generated `.c` out of the way, so the next run has to write it
  ## again rather than hit `generateCode`'s "unchanged, keep mtime" branch.
  let produced = mainOutput(backendDir)
  if not fileExists(produced):
    bail "lengc produced no " & produced
    return
  moveFile(produced, saveAs)

# --- 1. two separate processes ---------------------------------------------

let expectA = scratch / "expect_a.c"
let expectB = scratch / "expect_b.c"

block twoProcesses:
  # The fixture build already wrote a `.c`; drop it so the run below has to
  # generate one rather than take `generateCode`'s "unchanged" branch.
  removeFile mainOutput(dirA)
  removeFile mainOutput(dirB)
  for (dir, saveAs) in [(dirA, expectA), (dirB, expectB)]:
    var cmd = quoteShell(lengcExe)
    for a in lengcArgs(dir): cmd.add " " & quoteShell(a)
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      bail "bin/lengc failed on " & dir & ":\n" & output
    else:
      expect output.len == 0, "bin/lengc printed something unexpected:\n" & output
      takeOutput(dir, saveAs)

if failures > 0:
  quit "FAILURE: " & $failures & " inproc/lengc test(s) failed"

# --- 2. one process, twice, with the reset in between ----------------------

let gotA = scratch / "got_a.c"
let gotB = scratch / "got_b.c"

block oneProcess:
  resetLengcGlobals()
  let codeA = runLengc(lengcArgs(dirA))
  expect codeA == QuitSuccess, "the first in-process run exited " & $codeA
  takeOutput(dirA, gotA)

  resetLengcGlobals()
  let codeB = runLengc(lengcArgs(dirB))
  expect codeB == QuitSuccess, "the second in-process run exited " & $codeB
  takeOutput(dirB, gotB)

if fileExists(gotA) and fileExists(expectA):
  expect readFile(gotA) == readFile(expectA),
    "the first in-process run differs from its own process"
if fileExists(gotB) and fileExists(expectB):
  expect readFile(gotB) == readFile(expectB),
    "the second in-process run differs from its own process; the first run " &
      "left state behind"

# The order must not matter either: B first, then A.
block reversedOrder:
  resetLengcGlobals()
  let codeB = runLengc(lengcArgs(dirB))
  expect codeB == QuitSuccess, "the reversed first run exited " & $codeB
  takeOutput(dirB, scratch / "rev_b.c")

  resetLengcGlobals()
  let codeA = runLengc(lengcArgs(dirA))
  expect codeA == QuitSuccess, "the reversed second run exited " & $codeA
  takeOutput(dirA, scratch / "rev_a.c")

if fileExists(scratch / "rev_a.c"):
  expect readFile(scratch / "rev_a.c") == readFile(expectA),
    "running B before A changed A's output"
if fileExists(scratch / "rev_b.c"):
  expect readFile(scratch / "rev_b.c") == readFile(expectB),
    "running A before B changed B's output"

# --- 3. the buffer overload equals the file path ----------------------------
#
# No file is read or written by `generateCode` here: the bytes go in as a
# `TokenBuf` and the translation unit comes back as a string.

proc cliState(): State =
  ## What `runLengc` builds for `lengc c --bits:64` before it calls into the
  ## backend: the C backend, 64-bit ints, console app, no `#line` directives.
  result = State(config: ConfigRef(), bits: 64)
  when defined(macos):
    result.config.cCompiler = ccCLang
  else:
    result.config.cCompiler = ccGcc
  result.config.appType = appConsole
  result.config.backend = backendC

proc fromBuffer(input: string): CodegenResult =
  ## The pure-buffer path: bytes -> `TokenBuf` -> `MainModule` -> C text. Written
  ## as a proc, not inline, because the module owns cursors into its own buffer
  ## and so must be *moved* into the backend — which Nim's move analysis only
  ## infers inside a routine.
  var raw = parseFromBuf(readFile(input), input)
  var m = loadFromBuf(raw, input)
  var s = cliState()
  s.config.nifcacheDir = input.parentDir
  result = generateCode(s, m, {codegen.gfMainModule})

proc fromSplitLoad(input: string): CodegenResult =
  ## `readSource` + `parseSource`, the two halves `load` is now made of.
  var m = parseSource(readSource(input), input)
  var s = cliState()
  s.config.nifcacheDir = input.parentDir
  result = generateCode(s, m, {codegen.gfMainModule})

block bufferOverload:
  for (input, expected) in [(inputA, expectA), (inputB, expectB)]:
    let r = fromBuffer(input)
    expect r.code == readFile(expected),
      "the buffer overload differs from the file path for " & input
    expect not r.hasHeader,
      "neither fixture exports a header, but one came back for " & input

block loadSplit:
  expect fromSplitLoad(inputA).code == readFile(expectA),
    "readSource/parseSource differs from the file path"

# --- 4. the CLI errors come back as exit codes ------------------------------
#
# `runLengc` prints what `quit msg` printed, on stderr, and returns instead of
# ending the process. The exact bytes are asserted against `bin/lengc` (which
# still ends its process); in-process only the code is asserted, because the
# diagnostic goes straight to this runner's stderr.

block errorPaths:
  for (args, want) in [(@["--bits:99"], "invalid value for --bits"),
                       (@["--cc:tcc"],
                        "unknown C compiler: 'tcc'. Available options are: gcc, clang"),
                       (@["nosuchcommand"], "invalid command: nosuchcommand"),
                       (@["c"], "command takes a filename")]:
    var cmd = quoteShell(lengcExe)
    for a in args: cmd.add " " & quoteShell(a)
    let (output, exitCode) = execCmdEx(cmd)
    expect exitCode == 1, "bin/lengc " & $args & " exited " & $exitCode
    expect output == want & "\n",
      "bin/lengc " & $args & " printed " & escape(output) & ", wanted " &
        escape(want & "\n")

  echo "[inproc/lengc] the four diagnostics below are the in-process error paths"
  for args in [@["--bits:99"], @["--cc:tcc"], @["nosuchcommand"], @["c"]]:
    resetLengcGlobals()
    expect runLengc(args) == 1, "runLengc " & $args & " must return 1"

if failures > 0:
  quit "FAILURE: " & $failures & " inproc/lengc test(s) failed"
echo "[inproc/lengc] all in-process lengc tests passed"
