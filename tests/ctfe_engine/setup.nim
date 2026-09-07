## Custom runner for the compile-time-evaluation ENGINE (`--ctfe:engine`,
## `src/nimony/engine.nim`, JIT_IMPL.md phase B2).
##
## `tests/ctfe_diff` already answers "does the engine compute the same values as
## the subprocess" over the whole consteval corpus. This directory answers the
## three questions that are about the engine's own machinery rather than about
## the values it produces, and that a differential run cannot see:
##
## 1. **It really skips the backend.** A `const` evaluated by the engine must
##    leave the sub-program as `.asm.nif` modules and NO object file, because
##    the build stopped after the analysis graph. If the C compiler and the
##    linker still ran, every value would still be right and the phase would be
##    worth nothing.
## 2. **The fallback works and is invisible.** An engine that refuses must hand
##    the evaluation back to the subprocess and produce the same program. The
##    refusal is forced with `NIMONY_CTFE_ENGINE=off` rather than with a program
##    arkham happens to reject today: which programs those are is a moving
##    target as arkham improves, and the path this test is about is the
##    compiler's, not arkham's.
## 3. **A runaway `const` is a diagnostic, not a hang.** The guest runs on a
##    thread of nimsem's, so without a budget an expression that loops forever
##    stops the compiler forever.
## 4. **A new evaluation costs no process before `cc`** (A2c). The sub-program's
##    build graphs run inside the compiler that needs their result, so the
##    compile must show no `nimony`/`nimsem`/`hexer` spawn for any of them.
## 5. **The stdlib closure is emitted once per nimcache, not once per
##    sub-program** (A2c). Every sub-program of one compile shares the seven
##    modules of `std/writenif`'s closure, and `dceEmit` used to rewrite all of
##    them for each one. The content-addressed `<nimcache>/ccache/` is checked
##    both for the sharing (fewer entries than emissions) and for being sound
##    (the same bytes as a compile with `NIMONY_CCACHE=off`).
##
## Needs a built `bin/nimony` (the tree walk's `tests/setup.hastur` provides
## it), and a nimsem with the engine compiled in — without the sibling
## `../nativenif` checkout there is nothing here to test, and the runner says so
## instead of passing vacuously.

import std / [os, osproc, strutils, monotimes, times, algorithm]
import "../../src/hastur/kit"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")

let here = currentSourcePath().parentDir
let caseDir = here / "cases"

var failures = 0

proc fail(what: string) =
  inc failures
  echo "  FAIL ", what

type
  Run = object
    ## One `nimony c` of one case file, and what it left behind.
    cache: string
    exe: string
    output: string      ## the compiler's own stdout+stderr
    code: int
    programOut: string
    programCode: int
    objects: int        ## `.o` files inside a sub-program directory
    asmModules: int     ## `.asm.nif` files inside a sub-program directory
    subPrograms: int    ## sub-program directories, i.e. evaluations
    foreignCNifs: int   ## non-main `.c.nif` files across all of them
    wallMs: float

proc isSubProgramDir(dir: string): bool =
  ## A compile-time-eval sub-program's backend directory, told apart from the
  ## outer program's and from the `std/writenif` precompile's by the shape of
  ## its name: `semos` names it `<3 letters><40 hex>`, a checksum of the
  ## evaluated expression, and nothing else in a nimcache is named that way.
  let name = dir.extractFilename
  if name.len != 43: return false
  for i in 3 ..< name.len:
    if name[i] notin {'0'..'9', 'A'..'F', 'a'..'f'}: return false
  result = true

proc measure(r: var Run) =
  ## Count what the sub-program directories hold. Only those: the outer
  ## program and the `writenif` precompile are ordinary compiles and have
  ## objects in both modes, which is not what this is asking about.
  r.objects = 0
  r.asmModules = 0
  r.subPrograms = 0
  r.foreignCNifs = 0
  if not dirExists(r.cache): return
  for kind, dir in walkDir(r.cache):
    if kind != pcDir or not isSubProgramDir(dir): continue
    inc r.subPrograms
    let mainName = dir.extractFilename & ".c.nif"
    for k2, f in walkDir(dir):
      if k2 != pcFile: continue
      if f.endsWith(".o"): inc r.objects
      elif f.endsWith(".asm.nif"): inc r.asmModules
      elif f.endsWith(".c.nif") and f.extractFilename != mainName:
        inc r.foreignCNifs

proc compileCase(label, file, flags: string; engineOff = false;
                 ccacheOff = false): Run =
  result = Run(cache: getTempDir() / "ctfe_engine" / $getCurrentProcessId() / label)
  removeDir result.cache
  createDir result.cache
  result.exe = result.cache / "prog".addFileExt(ExeExt)
  var cmd = quoteShell(toolExe("nimony")) & " c --isMain " & flags &
            " --nimcache:" & quoteShell(result.cache) &
            " --out:" & quoteShell(result.exe) &
            " " & quoteShell(file)
  if engineOff: putEnv("NIMONY_CTFE_ENGINE", "off")
  if ccacheOff: putEnv("NIMONY_CCACHE", "off")
  let t0 = getMonoTime()
  let (output, code) = execCmdEx(cmd)
  result.wallMs = (getMonoTime() - t0).inNanoseconds.float / 1e6
  if engineOff: delEnv("NIMONY_CTFE_ENGINE")
  if ccacheOff: delEnv("NIMONY_CCACHE")
  result.output = output
  result.code = code
  result.programOut = ""
  result.programCode = 0
  if code == 0 and fileExists(result.exe):
    let (po, pc) = execCmdEx(quoteShell(result.exe))
    result.programOut = po
    result.programCode = pc
  measure result

const ExpectedOutput = "1\n3\n6\n10\n15\n21\n"

# ---- 1. the engine leaves no object file behind ----------------------------

proc checkNoBackendRan() =
  echo "ctfe_engine: the engine does not run the C backend"
  let sub = compileCase("subprocess", caseDir / "tsimpleconst.nim",
                        "--ctfe:subprocess")
  let eng = compileCase("engine", caseDir / "tsimpleconst.nim", "--ctfe:engine")

  if sub.code != 0:
    fail "the subprocess mode did not compile: " & sub.output
  if eng.code != 0:
    fail "the engine mode did not compile: " & eng.output
  if sub.programOut != ExpectedOutput:
    fail "subprocess program printed " & sub.programOut.escape
  if eng.programOut != ExpectedOutput:
    fail "engine program printed " & eng.programOut.escape

  # The baseline: the subprocess path DOES compile and link objects, so the
  # engine's zero below is a real difference and not an artefact of counting
  # the wrong directory.
  if sub.objects == 0:
    fail "the subprocess mode compiled no object at all — the count is wrong, " &
         "not the engine"
  else:
    echo "  subprocess: ", sub.objects, " object(s), ", sub.asmModules,
         " .asm.nif in the sub-program directories"

  if eng.objects != 0:
    fail "the engine mode still produced " & $eng.objects &
         " object file(s): the backend graph ran after all"
  elif eng.asmModules == 0:
    fail "the engine mode produced no .asm.nif: nothing was assembled in-process"
  else:
    echo "  engine:     ", eng.objects, " object(s), ", eng.asmModules,
         " .asm.nif in the sub-program directories"

# ---- 2. a refusal falls back, and the program is still right ---------------

proc checkFallback() =
  echo "ctfe_engine: a refused evaluation falls back to the subprocess"
  let r = compileCase("fallback", caseDir / "tsimpleconst.nim",
                      "--ctfe:engine", engineOff = true)
  if r.code != 0:
    fail "the fallback did not compile: " & r.output
    return
  if r.programOut != ExpectedOutput:
    fail "the fallback program printed " & r.programOut.escape
  if r.objects == 0:
    fail "the fallback produced no object file: the subprocess path did not run"
  else:
    echo "  fallback:   ", r.objects, " object(s) — the subprocess path ran, ",
         "and the value is unchanged"

# ---- 3. a runaway `const` is a diagnostic --------------------------------

proc checkBudget() =
  echo "ctfe_engine: an evaluation that never ends is a diagnostic"
  # A short budget so the test costs a second rather than ten. The point is the
  # mechanism, and 1.5 s is as infinite as 10 s for a loop with no exit.
  let r = compileCase("budget", caseDir / "trunaway.nim",
                      "--ctfe:engine --ctfe-budget:1500")
  if r.code == 0:
    fail "a `const` that never finishes compiled successfully"
    return
  if "exceeded its budget" notin r.output:
    fail "the diagnostic does not mention the budget:\n" & r.output
    return
  echo "  budget:     the compile stopped after ",
       formatFloat(r.wallMs, ffDecimal, 0), " ms with the budget diagnostic"

# ---- 4. a new evaluation costs no process before `cc` (A2c) ---------------

const ManyExpected = "1\n3\n6\n10\nababab\n111\n-----\n"

proc countLines(output, needle: string): int =
  result = 0
  for line in output.splitLines:
    if line.startsWith(needle): inc result

proc checkNoSubprocess() =
  echo "ctfe_engine: a new evaluation spawns no compiler process"
  # `--verbose` makes the compiler say which of the two paths each sub-build
  # took (`semos.runNestedBuild`). Reading it off the compiler is what makes
  # this robust: counting processes from the outside is a race, and the
  # filesystem looks the same either way -- the spawned child wrote the very
  # same graphs into the very same nimcache.
  let r = compileCase("nospawn", caseDir / "tmanyconsts.nim", "--verbose")
  if r.code != 0:
    fail "the compile failed: " & r.output
    return
  if r.programOut != ManyExpected:
    fail "the program printed " & r.programOut.escape
  let inproc = countLines(r.output, "[ctfe-build] in-process")
  let spawned = countLines(r.output, "[ctfe-build] spawning")
  if r.subPrograms < 2:
    fail "expected several sub-programs, got " & $r.subPrograms &
         " -- the case no longer exercises what this checks"
  elif inproc < r.subPrograms:
    fail "only " & $inproc & " of " & $r.subPrograms &
         " sub-builds ran in-process"
  elif spawned != 0:
    fail $spawned & " sub-build(s) still spawned a `nimony s`"
  else:
    echo "  ", r.subPrograms, " sub-program(s), ", inproc,
         " sub-build(s) in-process (the `std/writenif` precompile included), ",
         spawned, " spawned"

# ---- 5. the stdlib closure is emitted once per nimcache, not per program ---

proc cNifFiles(cache: string): seq[(string, string)] =
  ## `(<sub-program>/<module>.c.nif, its bytes)` for the NON-MAIN modules of
  ## every sub-program -- the ones the cache is about.
  ##
  ## The main module is left out because it cannot be compared across two
  ## nimcaches at all: the snippet writes its result to an absolute path, so
  ## its Leng IR carries that path and the `strlit.0.I<hash>` name derived from
  ## it. It is also the one module the cache never touches, its suffix being a
  ## checksum of the evaluated expression.
  result = @[]
  if not dirExists(cache): return
  for kind, dir in walkDir(cache):
    if kind != pcDir or not isSubProgramDir(dir): continue
    let mainName = dir.extractFilename & ".c.nif"
    for k2, f in walkDir(dir):
      if k2 == pcFile and f.endsWith(".c.nif") and f.extractFilename != mainName:
        result.add (dir.extractFilename / f.extractFilename, readFile(f))
  result.sort

proc checkCNifCache() =
  echo "ctfe_engine: the stdlib closure's `.c.nif` is shared across sub-programs"
  let on = compileCase("ccache_on", caseDir / "tmanyconsts.nim", "")
  let off = compileCase("ccache_off", caseDir / "tmanyconsts.nim", "",
                        ccacheOff = true)
  if on.code != 0 or off.code != 0:
    fail "the compile failed: " & on.output & off.output
    return
  if on.programOut != ManyExpected or off.programOut != ManyExpected:
    fail "the program printed differently with and without the cache"
    return

  # Sharing: `dceEmit` produced `foreignCNifs` files, but only the distinct ones
  # were ever computed -- the rest were written from `ccache/`. Its entry count
  # is that distinct number, and it has to be smaller or the cache did nothing.
  var entries = 0
  let dir = on.cache / "ccache"
  if dirExists(dir):
    for kind, f in walkDir(dir):
      if kind == pcFile and f.endsWith(".c.nif"): inc entries
  if entries == 0:
    fail "no `ccache/` entries at all: the cache never ran"
  elif entries >= on.foreignCNifs:
    fail "the cache holds " & $entries & " entries for " & $on.foreignCNifs &
         " emissions: nothing was shared between sub-programs"
  else:
    echo "  ", on.subPrograms, " sub-program(s), ", on.foreignCNifs,
         " non-main `.c.nif` written from ", entries, " distinct one(s)"

  # Soundness: the cache is keyed on a slice of `<main>.live.nif`, so the check
  # that matters is that a compile which never consults it produces the same
  # bytes. This is the only test that can make it -- `tests/ctfe_diff`'s modes
  # all share one cache.
  let a = cNifFiles(off.cache)
  let b = cNifFiles(on.cache)
  if a.len != b.len:
    fail "the two compiles produced " & $a.len & " and " & $b.len &
         " `.c.nif` files"
    return
  var differing = 0
  for i in 0 ..< a.len:
    if a[i][0] != b[i][0] or a[i][1] != b[i][1]: inc differing
  if differing > 0:
    fail $differing & " of " & $a.len &
         " `.c.nif` files differ from the `NIMONY_CCACHE=off` compile"
  else:
    echo "  ", a.len,
         " non-main `.c.nif` file(s) byte-identical to `NIMONY_CCACHE=off`"

# ---- run ------------------------------------------------------------------

if not engineIsCompiledIn():
  echo "ctfe_engine: nimsem has no compile-time-evaluation engine " &
       "(no ../nativenif at build time); nothing to test"
  quit 0

checkNoBackendRan()
checkFallback()
checkBudget()
checkNoSubprocess()
checkCNifCache()

removeDir getTempDir() / "ctfe_engine" / $getCurrentProcessId()

if failures > 0:
  echo "ctfe_engine: ", failures, " failure(s)"
  quit 1
echo "ctfe_engine: all checks passed"
