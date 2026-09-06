## The CTFE differential harness: compile the same sources twice under two sets
## of nimony flags and prove that compile-time evaluation produced the same
## bytes both times.
##
## Every `const` nimony cannot fold in-process becomes a whole sub-compiled
## program whose result is written back as NIF: `semos.runEval` writes
## `<nifcache>/<sfx>.p.nif`, runs it, and parses `<nifcache>/<sfx>.out.nif`.
## Those `.out.nif` files ARE the evaluation results, so a change to how the
## compiler reaches them — a VFS mode, an in-process pipeline, a JIT behind
## `executeExpr` — is correct exactly when they come back byte for byte
## identical. That is the oracle this module implements, and it is deliberately
## dumber than a semantic comparison: a NIF file that differs in whitespace or
## in symbol disambiguation is still a difference worth a human look.
##
## The two modes are strings of nimony CLI flags, the empty string included, so
## the harness is written once and reused as the flags come into existence:
## disk vs disk today, `--vfs:disk` vs `--vfs:memory+spill` after A1b,
## `--ctfe:subprocess` vs `--ctfe:engine` after B2.
##
## Each mode gets ONE nimcache for the whole run, not one per file: the stdlib
## sub-compiles dominate a cold cache, and paying them per test would make the
## harness cost minutes instead of seconds. Attribution survives because the
## set of `*.out.nif` names is snapshotted before each file and diffed after —
## whatever appeared belongs to that file. Names are checksums of the
## expression, so two tests sharing an expression share the artifact, and it is
## compared under whichever test reached it first.

import std / [syncio, os, osproc, strutils, algorithm, sets]
import context

const
  ExcerptRadius = 48
    ## How much of a NIF file to quote either side of the first differing byte.
    ## Wide enough to hold the enclosing token and its neighbours in the text
    ## NIF `.out.nif` files carry, narrow enough to stay one line.

type
  ModeRun = object
    ## One side of the comparison. `cache` is that mode's nimcache for the
    ## whole run; `seen`/`fresh` is how a file's own artifacts are told apart
    ## from everything the earlier files left behind.
    flags: string
    cache: string
    exe: string
    compileOut: string
    compileCode: int
    programOut: string
    programCode: int
    seen: HashSet[string]
    fresh: seq[string]

  CtfeDiffCtx = object
    ## The run: the toolchain to drive it with, the two modes, and the tally
    ## the exit code is made of.
    nimonyExe: string
    a, b: ModeRun
    files: int
    artifacts: int
    differences: int

# ---- reporting ------------------------------------------------------------

proc escapeExcerpt(s: string): string =
  ## NIF is line-oriented text with significant leading space, so a raw excerpt
  ## would break the report's alignment and hide exactly the whitespace a
  ## byte-level difference is most likely to be about.
  result = newStringOfCap(s.len + 8)
  for c in items s:
    case c
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c

proc nifExcerpt(s: string; at: int): string =
  ## The bytes around `at`, with the offset itself marked. `at` may sit one
  ## past the end when one file is a prefix of the other.
  let lo = max(0, at - ExcerptRadius)
  let hi = min(s.len, at + ExcerptRadius)
  result = ""
  if lo > 0: result.add "…"
  result.add escapeExcerpt(s[lo ..< min(at, hi)])
  result.add "◀HERE▶"
  if at < hi: result.add escapeExcerpt(s[at ..< hi])
  if hi < s.len: result.add "…"

proc firstDifference(x, y: string): int =
  ## Byte offset of the first difference, or -1 when the two are equal. A
  ## shorter file that is a prefix of the longer one differs at its own length.
  let n = min(x.len, y.len)
  var i = 0
  while i < n:
    if x[i] != y[i]: return i
    inc i
  if x.len == y.len: -1 else: n

proc noteDifference(c: var CtfeDiffCtx; what: string) =
  inc c.differences
  echo "  DIFF ", what

# ---- artifact comparison --------------------------------------------------

proc outNifNames*(cache: string): HashSet[string] =
  ## Every `*.out.nif` under `cache`, by name relative to it. Recursive: the
  ## backend puts per-module artifacts in `<cache>/<mod><tag>/`, and while
  ## `runEval` writes to the cache root today, a name is a name and the
  ## harness should not need editing when that moves.
  result = initHashSet[string]()
  if not dirExists(cache): return
  for p in walkDirRec(cache, relative = true):
    if p.endsWith(".out.nif"): result.incl p

proc compareArtifacts*(cacheA, cacheB: string; names: seq[string]): int =
  ## Compare the named `*.out.nif` files between two nimcaches, byte for byte.
  ## Returns the number that differ, printing one report line each. Shared by
  ## the per-file walk and the self-test, so the self-test proves the
  ## comparison the real run uses.
  result = 0
  for name in items names:
    let pa = cacheA / name
    let pb = cacheB / name
    let hasA = fileExists(pa)
    let hasB = fileExists(pb)
    if not hasA or not hasB:
      # An evaluation that happened under one mode and not the other is a
      # difference even though there is nothing to diff: the modes disagreed
      # about what needed evaluating at all.
      inc result
      echo "  DIFF ", name, ": present only in mode ",
           (if hasA: "A" else: "B")
      continue
    let da = readFile(pa)
    let db = readFile(pb)
    let at = firstDifference(da, db)
    if at < 0: continue
    inc result
    echo "  DIFF ", name, ": first differing byte at offset ", at,
         " (", da.len, " bytes in A, ", db.len, " in B)"
    echo "    A: ", nifExcerpt(da, at)
    echo "    B: ", nifExcerpt(db, at)

# ---- one file, one mode ---------------------------------------------------

proc compileIn(m: var ModeRun; nimonyExe, file: string) =
  ## Compile `file` into this mode's cache, pinning the executable so the
  ## harness does not have to re-derive nimony's module-suffix naming.
  m.exe = m.cache / "ctfediff_prog".addFileExt(ExeExt)
  removeFile m.exe
  var cmd = quoteShell(nimonyExe) & " c --isMain"
  if m.flags.len > 0: cmd.add " " & m.flags
  cmd.add " --nimcache:" & quoteShell(m.cache)
  cmd.add " --out:" & quoteShell(m.exe)
  cmd.add " " & quoteShell(file)
  let (output, code) = execCmdEx(cmd)
  m.compileOut = output
  m.compileCode = code

proc runCompiled(m: var ModeRun) =
  ## Run what the compile produced. A test whose point is a compile error has
  ## no executable; that is not a failure here, only the absence of a stdout to
  ## compare.
  m.programOut = ""
  m.programCode = 0
  if m.compileCode != 0 or not fileExists(m.exe): return
  let (output, code) = execCmdEx(quoteShell(m.exe))
  m.programOut = output
  m.programCode = code

proc freshArtifacts(m: var ModeRun) =
  ## What this file's compile added to the mode's cache.
  m.fresh = @[]
  let now = outNifNames(m.cache)
  for name in items now:
    if name notin m.seen: m.fresh.add name
  m.seen = now
  sort m.fresh

proc diffOneFile(c: var CtfeDiffCtx; file: string) =
  inc c.files
  compileIn(c.a, c.nimonyExe, file)
  compileIn(c.b, c.nimonyExe, file)
  freshArtifacts c.a
  freshArtifacts c.b

  let before = c.differences

  # A compile that fails under BOTH modes is fine — `tconstunsupported.nim` is
  # exactly that, and its diagnostic is the point of the test. Failing under
  # only one mode is the whole reason this harness exists.
  if (c.a.compileCode == 0) != (c.b.compileCode == 0):
    noteDifference c, file & ": compiled under mode " &
      (if c.a.compileCode == 0: "A" else: "B") & " only"
    echo "    A (exit ", c.a.compileCode, "): ", c.a.compileOut.strip
    echo "    B (exit ", c.b.compileCode, "): ", c.b.compileOut.strip

  var names: seq[string] = @[]
  var union = initHashSet[string]()
  for n in items c.a.fresh: union.incl n
  for n in items c.b.fresh: union.incl n
  for n in items union: names.add n
  sort names
  c.artifacts += names.len
  c.differences += compareArtifacts(c.a.cache, c.b.cache, names)

  if c.a.compileCode == 0 and c.b.compileCode == 0:
    runCompiled c.a
    runCompiled c.b
    if c.a.programOut != c.b.programOut:
      noteDifference c, file & ": the compiled program printed differently"
      echo "    A: ", c.a.programOut.strip
      echo "    B: ", c.b.programOut.strip
    elif c.a.programCode != c.b.programCode:
      noteDifference c, file & ": the compiled program exited " &
        $c.a.programCode & " under A, " & $c.b.programCode & " under B"

  if c.differences == before:
    echo "  ok ", file, " (", names.len, " artifact(s))"

# ---- the walk -------------------------------------------------------------

proc nimFilesOf(dir: string): seq[string] =
  ## The directory's own `.nim` files, sorted. Non-recursive on purpose: a test
  ## directory's subdirectories hold import fixtures (`doc/`) and cases that do
  ## not work yet (`todo/`), never tests — the same rule `hastur`'s own tree
  ## walk applies to a leaf directory.
  result = @[]
  if not dirExists(dir):
    echo "ctfediff: not a directory: ", dir
    return
  for x in walkDir(dir):
    if x.kind != pcFile: continue
    let name = x.path.extractFilename
    if not name.endsWith(".nim"): continue
    if name == "setup.nim" or name.startsWith("_hastur"): continue
    result.add x.path
  sort result

proc initMode(flags, cache: string): ModeRun =
  removeDir cache
  createDir cache
  result = ModeRun(flags: flags, cache: cache, seen: initHashSet[string](),
                   fresh: @[])

proc engineIsCompiledIn*(probe = "tests/nimony/consteval/tconstarray.nim"): bool =
  ## Whether the `bin/nimsem` in use actually HAS the compile-time-evaluation
  ## engine (`--ctfe:engine`, `src/nimony/engine.nim`). It is compiled in only
  ## where the sibling `../nativenif` checkout exists at build time, and a
  ## nimsem without it accepts `--ctfe:engine` and quietly evaluates every
  ## `const` through the subprocess — which is right (the flag is a preference,
  ## not a demand), and would make a differential run against it vacuous.
  ##
  ## Asked by EVIDENCE rather than by a version string or a `dirExists`: compile
  ## one `const` under `--ctfe:engine` and look at what the nimcache holds
  ## afterwards. The engine leaves the sub-program's modules as `.asm.nif` and
  ## no `.o` at all, because its build stops after the analysis graph; the
  ## subprocess path leaves an object per module. That is the difference the
  ## flag is supposed to make, so it is the right thing to test for.
  let cache = getTempDir() / "ctfe_engine_probe" / $getCurrentProcessId()
  removeDir cache
  createDir cache
  var cmd = quoteShell(toolExe("nimony")) & " c --isMain --ctfe:engine" &
            " --nimcache:" & quoteShell(cache) &
            " --out:" & quoteShell(cache / "probe".addFileExt(ExeExt)) &
            " " & quoteShell(probe)
  let (_, code) = execCmdEx(cmd)
  result = false
  if code == 0:
    for path in walkDirRec(cache):
      if path.endsWith(".asm.nif"):
        result = true
        break
  removeDir cache

proc ctfeDiff*(dirs: seq[string]; modeA, modeB: string): int =
  ## Compile every `.nim` directly under each of `dirs` twice — once with
  ## `modeA`'s flags, once with `modeB`'s — and compare what compile-time
  ## evaluation produced: every `*.out.nif` the compile added to that mode's
  ## nimcache, and the compiled program's own stdout. Returns the number of
  ## differences, so zero is the passing verdict.
  let root = getTempDir() / "ctfediff" / $getCurrentProcessId()
  var c = CtfeDiffCtx(
    nimonyExe: toolExe("nimony"),
    a: initMode(modeA, root / "a"),
    b: initMode(modeB, root / "b"))

  echo "ctfediff: mode A = \"", modeA, "\", mode B = \"", modeB, "\""
  for dir in items dirs:
    echo "ctfediff: ", dir
    for f in items nimFilesOf(dir):
      diffOneFile c, f

  echo "ctfediff: ", c.files, " file(s), ", c.artifacts, " artifact(s), ",
       c.differences, " difference(s)"
  # The caches are large and only interesting when something went wrong.
  if c.differences == 0:
    removeDir root
  else:
    echo "ctfediff: caches kept for inspection: ", root
  result = c.differences

# ---- self-test ------------------------------------------------------------

proc ctfeDiffSelfTest*(): int =
  ## Prove the comparison is not vacuous: two caches holding one identical
  ## `.out.nif`, one that differs in a single byte, and one present on only one
  ## side. Exactly the latter two must be reported, and the identical one must
  ## not be. Returns the number of failures.
  let root = getTempDir() / "ctfediff_selftest" / $getCurrentProcessId()
  let ca = root / "a"
  let cb = root / "b"
  removeDir root
  createDir ca
  createDir cb

  const Same = "(oconstr(object .\n (fld :len.0 . .\n  (i 64).))(kv len.0 3))"
  writeFile ca / "same.out.nif", Same
  writeFile cb / "same.out.nif", Same
  writeFile ca / "changed.out.nif", " 42\n"
  writeFile cb / "changed.out.nif", " 43\n"
  writeFile ca / "onlya.out.nif", " 1\n"

  var names: seq[string] = @[]
  for n in items outNifNames(ca): names.add n
  for n in items outNifNames(cb):
    if n notin names: names.add n
  sort names

  echo "ctfediff self-test: comparing ", names.len, " artifact(s)"
  let reported = compareArtifacts(ca, cb, names)

  result = 0
  if names.len != 3:
    echo "  FAIL: expected 3 artifacts, collected ", names.len
    inc result
  if reported != 2:
    echo "  FAIL: expected 2 differences (changed + present-in-A-only), got ",
         reported
    inc result
  if result == 0:
    echo "  ok: the identical artifact passed and both differing ones were reported"
  removeDir root
