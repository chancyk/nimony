## Custom runner for phase A2a-front: the frontend tools must produce the same
## bytes when they run twice in ONE process as when they run in two.
##
## That is the whole claim behind `runNifler` / `runNimsem` and
## `resetNiflerGlobals` / `resetFrontendGlobals` (`JIT.md` 6.1). It is worth a
## test of its own because the failure mode is silent: the frontend interns
## every identifier, symbol and filename into one process-global pool, and a
## `SymId` is an index into it. Let two modules share a pool without a reset
## and the second one's output can pick up whatever the first one interned —
## which shows up as a byte difference in its `.s.nif`, and nowhere else.
##
## Two sections, both differential and both against the real tools:
##
## a) `bin/nifler` twice vs `runNifler` twice, on two different `.nim` files.
## b) `bin/nimsem` twice vs `runNimsem` twice, on two different modules — a
##    library module and a module that imports it, in that order, which is
##    exactly the sequence the A2b scheduler will run in one process. The
##    second run must read the first module's interface back from its
##    `.s.idx.nif`/`.s.nif` and not from whatever the first run left in
##    `programs.prog`.
##
## The argument vectors are not invented here: they are read out of the
## `.build.nif` that `nimony c` wrote, so the test drives the tools with the
## command lines the build system drives them with.

import std / [os, strutils, syncio, sequtils]
import "../../../src/hastur/kit"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")

var failures = 0

proc fail(msg: string) =
  echo "  FAIL: ", msg
  inc failures

proc ok(msg: string) =
  echo "  ok: ", msg

# ── the two modules under test ───────────────────────────────────────────────
#
# Written out rather than checked in: a `.nim` file in a directory owned by a
# `setup.nim` is not run by anything, so it would only look like a test that
# never runs. They exercise what a leak would ride on — the same spellings
# declared in both modules, doc comments (the host parser's comment table, the
# one piece of state nifler cannot reset) and an import of one by the other.

const SourceA = """
## A library module.

type
  Thing* = object ## something to name a type after
    id*: int
    label*: string

proc make*(id: int; label: string): Thing =
  ## Doc comment, so the parser's comment table is exercised.
  result = Thing(id: id, label: label)

proc describe*(t: Thing): string =
  t.label & "/" & $t.id

const Base* = 21
"""

const SourceB = """
import ma

## A module that imports the one above, and reuses its spellings.

type
  Thing* = object ## a DIFFERENT Thing with the same name
    tag*: int

proc make*(tag: int): Thing = Thing(tag: tag)

proc describe*(t: Thing): string = "tag " & $t.tag

proc run*(): string =
  let a = ma.make(Base, "left")
  let b = make(7)
  result = ma.describe(a) & " " & describe(b)
"""

# ── reading argument vectors out of a `.build.nif` ───────────────────────────

proc unescapeNif(s: string): string =
  ## NIF string literals escape a byte as `\HH`; the build file's arguments are
  ## full of `\3A` for the `:` in `--nimcache:...`.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 2 < s.len:
      result.add chr(parseHexInt(s[i+1 .. i+2]))
      i += 3
    else:
      result.add s[i]
      inc i

proc quotedStrings(line: string): seq[string] =
  result = @[]
  var i = 0
  while i < line.len:
    if line[i] == '"':
      var j = i + 1
      var s = ""
      while j < line.len and line[j] != '"':
        s.add line[j]
        inc j
      result.add unescapeNif(s)
      i = j + 1
    else:
      inc i

proc commandOf(buildFile, tool: string): seq[string] =
  ## The `(cmd :<tool> "<exe>" "<flag>" … "<command>")` template, minus the
  ## executable: the fixed head of every invocation of that tool.
  result = @[]
  for line in lines(buildFile):
    let s = line.strip
    if s.startsWith("(cmd :" & tool & " "):
      result = quotedStrings(s)
      if result.len > 0: result.delete(0)   # the executable
      return

proc nodeArgs(buildFile, tool: string): seq[seq[string]] =
  ## Every `(do <tool> … (args …))` node's own arguments, in file order.
  result = @[]
  var inNode = false
  for line in lines(buildFile):
    let s = line.strip
    if s.startsWith("(do " & tool):
      inNode = true
    elif inNode and s.startsWith("(args"):
      result.add quotedStrings(s)
      inNode = false

proc parsedFileOf(buildFile, source: string): string =
  ## The `.p.nif` the build file has nifler produce for `source`.
  result = ""
  var pending = false
  for line in lines(buildFile):
    let s = line.strip
    if s.startsWith("(do nifler"):
      pending = true
    elif pending and s.startsWith("(input"):
      let ins = quotedStrings(s)
      pending = ins.len > 0 and ins[0].extractFilename == source
    elif pending and s.startsWith("(output"):
      let outs = quotedStrings(s)
      if outs.len > 0: return outs[0]
      pending = false

# ── running things ───────────────────────────────────────────────────────────

proc moduleExt(p, ext: string): string =
  ## `gear2/modnames.changeModuleExt` for a runner that does not import it:
  ## a nimcache name is `<suffix>.<phase>.nif`, so everything from the FIRST
  ## dot is the extension (`changeFileExt` would only replace `.nif`).
  let dir = p.parentDir
  var name = p.extractFilename
  let dot = name.find('.')
  if dot >= 0: name = name[0 ..< dot]
  result = dir / name & ext

proc writeRunFile(path: string; runs: seq[seq[string]]) =
  ## One argument per line, runs separated by a blank line — the format both
  ## drivers read. A file, not a command line, so an argument may contain
  ## anything a path may contain.
  var s = ""
  for i, argv in runs:
    if i > 0: s.add "\n"
    for a in argv: s.add a & "\n"
  writeFile(path, s)

proc buildDriver(dir, name, cache: string): string =
  ## Compile one driver the way the toolchain itself is compiled. Two sets of
  ## switches have to be repeated here rather than inherited: `builders.nimcPrefix`
  ## (release plus the two warning overrides Nim 2.2.10's own stdlib needs), and
  ## `src/config.nims`, which reaches a build whose project file is under `src/`
  ## and not one whose project file is here. Of the latter, `strictDefs` is not
  ## optional — the frontend is written against it (`renderer.nim` has a `let`
  ## with no initialiser) — and `nimPreviewSlimSystem` goes with it so the
  ## driver links the same modules the tools do.
  ##
  ## The binary goes into the TOOLCHAIN directory, next to `bin/nimsem`, and
  ## not into the work directory: nimsem finds the stdlib relative to its own
  ## executable (`semos.nimonyDir` — the parent of a `bin*` directory), so a
  ## driver anywhere else would sem against a `lib/` that is not there.
  result = binDir() / name.addFileExt(ExeExt)
  let src = dir / name & ".nim"
  exec "nim c -d:release --hints:off --warningAsError:ProveInit:off" &
       " --warningAsError:Uninit:off --experimental:strictDefs" &
       " --define:nimPreviewSlimSystem --nimcache:" &
       (cache / "nc" / name).quoteShell &
       " -o:" & result.quoteShell & " " & src.quoteShell

proc snapshot(files: seq[string]; into: string) =
  createDir into
  for f in files:
    copyFile(f, into / f.extractFilename)

proc removeAll(files: seq[string]) =
  for f in files: removeFile f

proc compare(files: seq[string]; refDir, label: string) =
  var same = 0
  for f in files:
    let a = refDir / f.extractFilename
    if not fileExists(f):
      fail label & ": " & f.extractFilename & " was not produced in-process"
    elif readFile(a) != readFile(f):
      fail label & ": " & f.extractFilename & " differs from the two-process output"
    else:
      inc same
  if same == files.len:
    ok label & ": " & $same & " output files byte-identical to two processes"

# ── setup: one `nimony c`, which produces the `.p.nif`s and the build file ───

let here = if arg("dir").len > 0: arg("dir") else: "tests/inproc/front"
let work = absolutePath(nimcacheDir) / "inproc_front"
let nc = work / "cache"
removeDir work
createDir work
createDir nc
writeFile(work / "ma.nim", SourceA)
writeFile(work / "mb.nim", SourceB)

exec toolExe("nimony").quoteShell & " c --nimcache:" & nc.quoteShell & " " &
     (work / "mb.nim").quoteShell

var buildFile = ""
for kind, p in walkDir(nc):
  if kind == pcFile and p.endsWith(".build.nif") and not p.endsWith(".final.build.nif"):
    buildFile = p
if buildFile.len == 0:
  echo "  FAIL: nimony c produced no .build.nif"
  quit 1

let pnifA = parsedFileOf(buildFile, "ma.nim")
let pnifB = parsedFileOf(buildFile, "mb.nim")
if pnifA.len == 0 or pnifB.len == 0:
  echo "  FAIL: the build file names no .p.nif for ma.nim/mb.nim"
  quit 1

# ── (a) nifler ───────────────────────────────────────────────────────────────

echo "nifler: two runs in one process == two processes"
block niflerSection:
  let head = commandOf(buildFile, "nifler")   # --portablePaths --deps parse
  if head.len == 0:
    fail "no (cmd :nifler …) in the build file"
    break niflerSection
  let refDir = work / "nifler_ref"
  let outDir = work / "nifler_out"
  createDir refDir
  createDir outDir

  var refOuts: seq[string] = @[]
  var outs: seq[string] = @[]
  var runs: seq[seq[string]] = @[]
  for m in ["ma", "mb"]:
    let src = work / m & ".nim"
    let refOut = refDir / m & ".p.nif"
    let inpOut = outDir / m & ".p.nif"
    exec toolExe("nifler").quoteShell & " " & head.mapIt(it.quoteShell).join(" ") &
         " " & src.quoteShell & " " & refOut.quoteShell
    refOuts.add refOut
    refOuts.add refDir / m & ".p.deps.nif"
    outs.add inpOut
    outs.add outDir / m & ".p.deps.nif"
    runs.add head & @[src, inpOut]

  let runFile = work / "nifler.runs"
  writeRunFile(runFile, runs)
  let driver = buildDriver(here, "driver_nifler", work / "build")
  exec driver.quoteShell & " " & runFile.quoteShell
  removeFile driver

  # The reference outputs carry their own names; compare pairwise by index.
  var same = 0
  for i in 0 ..< refOuts.len:
    if not fileExists(outs[i]):
      fail "nifler: " & outs[i].extractFilename & " was not produced in-process"
    elif readFile(refOuts[i]) != readFile(outs[i]):
      fail "nifler: " & outs[i].extractFilename & " differs from the one-process output"
    else:
      inc same
  if same == refOuts.len:
    ok "nifler: " & $same & " output files byte-identical to two processes"

# ── (b) nimsem ───────────────────────────────────────────────────────────────

echo "nimsem: two runs in one process == two processes"
block nimsemSection:
  let head = commandOf(buildFile, "nimsem")   # --base:… --nimcache:… … m
  if head.len == 0:
    fail "no (cmd :nimsem …) in the build file"
    break nimsemSection

  # The two modules' own nodes, in dependency order: the library first, then
  # the module that imports it.
  var argsA: seq[string] = @[]
  var argsB: seq[string] = @[]
  for a in nodeArgs(buildFile, "nimsem"):
    if a.len > 0:
      if a[^1] == pnifA: argsA = a
      elif a[^1] == pnifB: argsB = a
  if argsA.len == 0 or argsB.len == 0:
    fail "the build file has no (do nimsem) node for ma/mb"
    break nimsemSection

  let outputs = @[
    moduleExt(pnifA, ".s.nif"), moduleExt(pnifA, ".s.idx.nif"),
    moduleExt(pnifA, ".s.deps.nif"),
    moduleExt(pnifB, ".s.nif"), moduleExt(pnifB, ".s.idx.nif"),
    moduleExt(pnifB, ".s.deps.nif")]

  # Two processes, from scratch.
  removeAll outputs
  for a in [argsA, argsB]:
    exec toolExe("nimsem").quoteShell & " " &
         (head & a).mapIt(it.quoteShell).join(" ")
  let refDir = work / "nimsem_ref"
  snapshot outputs, refDir

  # One process, twice, with the reset in between.
  removeAll outputs
  let runFile = work / "nimsem.runs"
  writeRunFile(runFile, @[head & argsA, head & argsB])
  let driver = buildDriver(here, "driver_nimsem", work / "build")
  exec driver.quoteShell & " " & runFile.quoteShell
  removeFile driver

  compare outputs, refDir, "nimsem"

if failures > 0:
  echo "inproc/front: ", failures, " failure(s)"
  quit 1
echo "SUCCESS."
