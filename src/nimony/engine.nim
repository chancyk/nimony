#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The Leng engine: a program assembled into this process's memory and called
## there instead of being linked and exec'd. Two customers, the two halves of
## JIT.md 7:
##
## * `evaluate` -- compile-time evaluation (`--ctfe:engine`, JIT.md 7.2), the
##   subject of everything down to `timingLine`;
## * `runWholeProgram` -- `nimony r` (JIT.md 7.3, JIT_IMPL.md B1), at the
##   bottom of the file, which starts one step later because the build graph's
##   arkham nodes have already produced every module's `.asm.nif`.
##
## They share the loader, the target dispatch and the timing record, and they
## differ in every place where a compiler evaluating a `const` and a user
## running a program genuinely want different things -- output capture, `kill`,
## the budget, and what a refusal means. Each difference is argued at the site
## that makes it.
##
## The rest of this header is about `evaluate`.
##
## A `const` that `expreval` cannot fold becomes a whole PROGRAM
## (`exprexec.executeExpr`), and the subprocess path compiles and links that
## program before running it: lengc, a C compiler per module, a linker, an exec.
## Everything below the `.c.nif` files is what this module replaces. It takes
## the module set the sub-program's ANALYSIS graph produced, runs arkham on it
## in this process, assembles the result into an arena with nifasm, and calls
## `main` there.
##
## Three properties this leans on, all measured (`notes/b2.md` §2):
##
## * The guest is a raw-syscall program. Thirteen external names, none of them
##   `malloc` or stdio: its allocator is its own `mmap`-backed region and its
##   I/O is `open`/`write`/`close` straight through. So the host resolves them
##   with `dlsym` and two heaps never share a pointer.
## * Its `main` RETURNS. `cExit` is the native backend's ending; the C-backend
##   entry point this runs ends in `return 0`, so the ordinary outcome costs no
##   parked thread.
## * `cAbort` does `kill(getpid(), SIGABRT)`. In this process `getpid()` is
##   nimsem's, so that call has to be taken away or an out-of-memory `const`
##   takes the compiler down with it. That is `hostKill` below.
##
## The engine never has to succeed. Anything arkham or nifasm refuses is an
## `AsmError`, and every refusal turns into `eoFallback`, which `semos.runEval`
## answers by running the subprocess path it would have run anyway (JIT.md 7.5).
## The one thing that is NOT a fallback is a budget overrun: re-running an
## expression that loops forever is not a recovery, it is the same hang again.

import std / [os, monotimes, times, syncio, strutils, algorithm]

import ".." / lib / [nifcore, nifcoreparse, nifchecksums]

import arkham / generate
import arkham / core / lengdecl
import nifasm / [driver, hostrun]
import nifasm / core / [hostsyms, asmerror]
import nifasm / image / memory

const
  AsmExt = ".asm.nif"
    ## What arkham's output for one module is cached under, beside the `.c.nif`
    ## it came from. Foreign modules are read back from here by nifasm's own
    ## lazy loader; only the MAIN module goes straight from arkham's buffer
    ## into the session, because that is the one whose literal pool becomes the
    ## session's pool.
  EngineOffEnv* = "NIMONY_CTFE_ENGINE"
    ## `NIMONY_CTFE_ENGINE=off` makes every evaluation refuse and fall back,
    ## without changing a command line -- so it reaches the `nimony s`
    ## sub-compiles too, the way `NIMONY_VFS` does.
  DefaultBudgetMs* = 10_000
    ## Ten seconds for one evaluation. Long enough that no honest `const` on a
    ## loaded machine trips it, short enough that a runaway one is a diagnostic
    ## in the time it takes to read the error.

type
  EngineOutcome* = enum
    eoRan        ## the guest ran to completion; `status` is what it returned
    eoFallback   ## the engine refuses this program; use the subprocess
    eoBudget     ## the guest ran past its budget and is still running

  EngineTimings* = object
    ## Where one evaluation's milliseconds went. Printed under `--verbose`.
    arkhamMs*, assembleMs*, layMs*, bindMs*, runMs*, totalMs*: float
    modules*, arkhamRuns*, cacheHits*: int
    viaFile*: bool   ## the main module went through `.asm.nif` after the
                     ## in-memory handoff was refused
    codeLen*, dataLen*, externals*: int

  EngineResult* = object
    outcome*: EngineOutcome
    status*: int      ## the guest's exit status, when it ran
    reason*: string   ## why it fell back, or what the budget was
    output*: string   ## what the guest wrote to fd 1 and fd 2
    timings*: EngineTimings

  Engine* = object
    ## Per-nimsem-process engine state. Threaded through `SemContext`, not a
    ## global: the only globals here are the two the C ABI forces (below).
    tags: TagPool            ## arkham's Leng tag pool, one per process
    started: bool
    disabled*: bool          ## no further evaluation may use the engine
    disabledReason*: string
    evaluations*: int        ## how many evaluations the engine has run

# ── the two globals the C ABI forces ────────────────────────────────────────
#
# An intercept is reached through a function pointer the GUEST holds, so it can
# carry no context but a module-level one — the same reason nativenif's
# `hostrun` keeps `gGuest`. It is sound for the same reason: one guest runs at a
# time in one process, and `runImage` refuses a second concurrent one.

type
  GuestIo = object
    capturing: bool
    captured: string

var gIo: GuestIo

proc rawHostWrite(fd: cint; buf: pointer; n: csize_t): int
  {.importc: "write", header: "<unistd.h>".}

proc hostWrite(fd: cint; buf: pointer; n: csize_t): int {.cdecl.} =
  ## The guest's `write`. Its own diagnostics go to fd 2 (`cWriteErr` behind
  ## `panic`) and its `echo` to fd 1; both are the subprocess path's captured
  ## output, so they are captured here rather than interleaved into the
  ## compiler's. Every other descriptor is the guest writing its `<sfx>.out.nif`
  ## and goes to the real syscall untouched — the result has to reach the disk,
  ## because `runEval` reads it back the same way in both modes.
  if gIo.capturing and (fd == 1 or fd == 2):
    let old = gIo.captured.len
    gIo.captured.setLen old + n.int
    if n.int > 0:
      copyMem(addr gIo.captured[old], buf, n.int)
    result = n.int
  else:
    result = rawHostWrite(fd, buf, n)

proc hostKill(pid: cint; sig: cint): cint {.cdecl.} =
  ## The guest's `kill`, taken away. `cAbort` raises SIGABRT at `getpid()` and
  ## then falls through to `_exit(127)`; in this process that pid is the
  ## COMPILER's, so the signal would kill nimsem instead of the guest. Doing
  ## nothing lets the guest reach its `_exit`, which is intercepted, so an
  ## aborting guest still comes back as an ordinary non-zero status.
  discard pid
  discard sig
  result = 0

# ── the engine ──────────────────────────────────────────────────────────────

proc initEngine*(): Engine =
  Engine(started: false, disabled: false, disabledReason: "", evaluations: 0)

proc hostTarget(): AsmTarget =
  ## The one target that matters: the host's own, because the guest is called
  ## in this process. Anything else has no arena to run in, so a cross compile
  ## keeps the subprocess path.
  when defined(macosx) and defined(arm64): atA64
  elif defined(linux) and defined(arm64): atLinuxA64
  elif defined(linux) and defined(amd64): atX64
  elif defined(windows) and defined(amd64): atWinX64
  else: atA64

proc engineByDefault*(): bool =
  ## Whether `--ctfe:auto` means the engine on this host. Only where it has
  ## been exercised end to end: macOS/arm64 (B0 tiers 27/27, B2 corpus 47/47,
  ## the whole test tree under `--ctfe:engine`). linux/x64 waits for arkham's
  ## `&threadvar` lowering under `--dev-single-thread` (B1 notes) and a run of
  ## the same suites there; until then `auto` is the subprocess on it.
  when defined(macosx) and defined(arm64): true
  else: false

proc hostIsSupported*(): bool =
  ## Whether the engine can run a guest on this host at all. `runImage` is
  ## POSIX-only on `jit/b1` and the arena needs a 64-bit address space.
  when defined(cpu64) and not defined(windows):
    when defined(macosx) or defined(linux): true
    else: false
  else:
    false

proc moduleSuffixOf(cnif: string): string =
  ## `<dir>/foo.c.nif` -> `foo`. `splitFile` takes the `.nif` off; the `.c` is
  ## the backend's own marker and is not part of the module's symbol suffix.
  result = cnif.splitFile.name
  if result.endsWith(".c"): result.setLen result.len - 2

proc asmIsFresh(asmFile, cnif, toolchain: string): bool =
  ## An `.asm.nif` may be reused when nothing that produced it moved. Same
  ## shape as `semos.evalMemoIsFresh`, one input shorter: the `.c.nif` it was
  ## generated from, and the nimsem binary that has arkham linked into it.
  if not fileExists(asmFile): return false
  var written = default(Time)
  try:
    written = getLastModificationTime(asmFile)
  except CatchableError:
    return false
  try:
    if getLastModificationTime(cnif) > written: return false
    if toolchain.len > 0 and getLastModificationTime(toolchain) > written:
      return false
  except CatchableError:
    return false
  result = true

proc collectModules(backendDir, mainSuffix: string; mainCNif: var string;
                    others: var seq[string]): bool =
  ## The sub-program's module set, as the analysis graph left it: every
  ## `.c.nif` in the backend directory. Returns false when the main module is
  ## not among them, which means the graph did not get that far.
  mainCNif = backendDir / mainSuffix & ".c.nif"
  others = @[]
  if not fileExists(mainCNif): return false
  try:
    for kind, path in walkDir(backendDir):
      if kind != pcFile: continue
      if not path.endsWith(".c.nif"): continue
      if path == mainCNif: continue
      others.add path
  except CatchableError:
    return false
  # Deterministic order: arkham is run per module and a diagnostic that names
  # "the first module that failed" must name the same one twice.
  sort others
  result = true

proc asmCacheKeys(others: seq[string]; mainCNif, toolStamp: string): seq[string] =
  ## One `.asm.nif` cache key per non-main module, or an empty seq when the
  ## inputs cannot be read (which simply means no caching for this evaluation).
  ##
  ## P0b's `fillObjectCache` keys a module's object on its own `.c.nif` plus
  ## every `.c.nif` it IMPORTS, because lengc splices inline bodies out of
  ## those. arkham reads foreign modules the same way (`nifmodules`), so the
  ## same class of input applies — but the engine sees a DIRECTORY, not a
  ## dependency graph, so it has to derive the set itself.
  ##
  ## It can, exactly: `openForeignModule` is only ever reached from a symbol,
  ## and a symbol names its module by suffix. A module arkham can open is
  ## therefore a module whose suffix occurs in this module's bytes. Searching
  ## for the eight suffixes is conservative in the safe direction — a suffix
  ## that occurs by coincidence adds a digest to the key and costs a cache
  ## miss, never a wrong hit.
  ##
  ## That precision is the whole value here. Keying on the whole directory
  ## instead measured 7 hits across five evaluations of `tmyops`; keying on
  ## what each module can actually read measured 28, because the stdlib closure
  ## is shared while the MAIN module — whose suffix is a checksum of the
  ## evaluated expression, so it differs every time — is only in the key of a
  ## module that really does reach into it.
  let n = others.len
  var names = newSeq[string](n + 1)
  var digests = newSeq[string](n + 1)
  var texts = newSeq[string](n)
  try:
    for i in 0 ..< n:
      names[i] = moduleSuffixOf(others[i])
      texts[i] = readFile(others[i])
      digests[i] = computeChecksum(texts[i])
    names[n] = moduleSuffixOf(mainCNif)
    digests[n] = computeChecksum(readFile(mainCNif))
  except CatchableError:
    return @[]
  let prefix = "arkham\n" & $hostTarget() & "\n" & toolStamp & "\n"
  result = newSeq[string](n)
  for i in 0 ..< n:
    var key = prefix & "self " & names[i] & " " & digests[i] & "\n"
    for j in 0 .. n:
      if j != i and texts[i].contains(names[j]):
        key.add names[j]
        key.add " "
        key.add digests[j]
        key.add "\n"
    result[i] = key

proc materialize(cached, local: string): bool =
  ## Put a cached `.asm.nif` where nifasm's lazy loader looks for it. A hard
  ## link rather than a copy: the file is a few hundred kilobytes, nothing ever
  ## writes to it, and the whole point of the cache is that this step is free.
  if not fileExists(cached): return false
  try:
    removeFile local
  except CatchableError:
    discard
  try:
    createHardlink(cached, local)
    return true
  except CatchableError:
    discard
  try:
    copyFile(cached, local)
    result = true
  except CatchableError:
    result = false

proc publish(local, cached: string) =
  ## Offer a freshly generated `.asm.nif` to the shared cache. Best effort: a
  ## cache that cannot be written is a slower compile, not a failed one.
  try:
    if fileExists(cached): return
    createDir cached.parentDir
    createHardlink(local, cached)
  except CatchableError:
    try:
      copyFile(local, cached)
    except CatchableError:
      discard

proc emitAsmFor(e: var Engine; cnif, asmFile: string; runs: var int) =
  ## arkham for one module, into the file nifasm's lazy loader will find. Can
  ## raise `AsmError`; the caller turns that into a fallback.
  var buf = parseFromFile(cnif, sharedTags = e.tags)
  let text = generateAsmText(buf, hostTarget(), cnif, e.tags)
  writeFile(asmFile, text)
  inc runs

proc callGuest(img: MemImage; budgetMs: int; sourceDir: string): GuestResult =
  ## `main(1, ["<ctfe>", nil], [nil])`. An EMPTY environment block rather than
  ## `nil`: nimony's synthesized `main` stores `envp` in `nimEnviron` and walks
  ## it if the evaluated expression ever asks for an environment variable, and
  ## walking a null pointer is a segfault where walking an empty block is an
  ## empty answer.
  ##
  ## `sourceDir` is the compiler's `workingDir` for the subprocess path, and it
  ## has to be honoured here too: a relative path in a `const`
  ## (`readFile("doc/version.md")`, `tests/nimony/consteval/tconstreadfile.nim`)
  ## resolves against the CALLING MODULE's directory, and the guest asks the OS
  ## the same question the subprocess did. In-process that means moving the
  ## compiler's own current directory for the length of the call — the guest
  ## thread is the only other thread there is, and everything the engine itself
  ## still touches by then is already open.
  var argStrings = ["nimony-ctfe".cstring, nil.cstring]
  var envStrings = [nil.cstring]
  var restore = ""
  if sourceDir.len > 0:
    try:
      restore = getCurrentDir()
      setCurrentDir sourceDir
    except CatchableError:
      restore = ""
  try:
    result = runImage(img, 1.cint, addr argStrings[0], addr envStrings[0],
                      budgetMs = budgetMs)
  finally:
    if restore.len > 0:
      try:
        setCurrentDir restore
      except CatchableError:
        discard

proc evaluate*(e: var Engine; backendDir, mainSuffix, sourceDir: string;
               budgetMs: int): EngineResult =
  ## Run one compile-time evaluation from `<backendDir>/*.c.nif`. Never raises:
  ## every refusal is an `EngineResult` the caller can act on.
  let t0 = getMonoTime()
  result = EngineResult(outcome: eoFallback, status: 0, reason: "", output: "")

  if e.disabled:
    result.reason = e.disabledReason
    return
  if not hostIsSupported():
    result.reason = "the engine has no runtime for this host"
    return
  if getEnv(EngineOffEnv) == "off":
    # The escape hatch that does not touch the command line, so it reaches the
    # `nimony s` sub-compiles too (`--vfs` travels the same way). It exists for
    # bisecting an engine-versus-subprocess disagreement without rebuilding,
    # and it is what `tests/ctfe_engine` uses to exercise the fallback: WHICH
    # programs arkham refuses is a moving target as arkham improves, so a test
    # that depends on one would rot, and the path worth testing is the
    # compiler's, not arkham's.
    result.reason = EngineOffEnv & "=off"
    return

  var mainCNif = ""
  var others: seq[string] = @[]
  if not collectModules(backendDir, mainSuffix, mainCNif, others):
    result.reason = "the analysis graph produced no " & mainSuffix & ".c.nif"
    return
  result.timings.modules = others.len + 1

  if not e.started:
    e.tags = createLengTagPool()
    e.started = true

  var toolchain = ""
  try:
    toolchain = getAppFilename()
  except CatchableError:
    toolchain = ""
  var toolStamp = toolchain
  try:
    if toolchain.len > 0:
      toolStamp.add " "
      toolStamp.add $getLastModificationTime(toolchain).toUnix
  except CatchableError:
    discard

  # ── arkham, in this process, once per module that needs it ────────────────
  #
  # Seven of a CTFE sub-program's eight modules are the stdlib closure of
  # `std/writenif` and are byte-identical from one sub-program to the next
  # (P0b measured exactly this for their objects). They land in per-sub-program
  # directories, though, so without a cache the SECOND evaluation of a compile
  # runs arkham over the same seven modules again — which is where nearly all
  # of this phase's time was.
  let cacheDir = backendDir.parentDir / "asmcache"
  var keys: seq[string] = @[]
  var keyed = false
  let tArkham = getMonoTime()
  var mainAsm = default(AsmModule)
  try:
    for i in 0 ..< others.len:
      let cnif = others[i]
      let asmFile = backendDir / moduleSuffixOf(cnif) & AsmExt
      if asmIsFresh(asmFile, cnif, toolchain): continue
      if not keyed:
        keys = asmCacheKeys(others, mainCNif, toolStamp)
        keyed = true
      if keys.len != others.len:
        emitAsmFor(e, cnif, asmFile, result.timings.arkhamRuns)
        continue
      let cached = cacheDir / computeChecksum(keys[i]) & AsmExt
      if materialize(cached, asmFile):
        inc result.timings.cacheHits
      else:
        emitAsmFor(e, cnif, asmFile, result.timings.arkhamRuns)
        publish(asmFile, cached)
    var mainBuf = parseFromFile(mainCNif, sharedTags = e.tags)
    mainAsm = generateAsmBuf(mainBuf, hostTarget(), mainCNif, e.tags)
    inc result.timings.arkhamRuns
  except AsmError as ex:
    result.reason = "arkham: " & ex.msg
    return
  except CatchableError as ex:
    result.reason = "arkham: " & ex.msg
    return
  except Defect as ex:
    result.reason = "arkham: " & ex.msg
    return
  result.timings.arkhamMs = (getMonoTime() - tArkham).inNanoseconds.float / 1e6

  # ── nifasm: one session over the whole module set ─────────────────────────
  #
  # Two ways in, tried in this order:
  #
  #  0. the MAIN module as arkham's own `TokenBuf`, its literal pool becoming
  #     the session's -- no serialization at all, and the reason `generateAsmBuf`
  #     exists.
  #  1. the same module written out as `.asm.nif` and re-read by
  #     `openFileSession`, which is the path nifasm's whole corpus and B1's
  #     `nifrun` exercise.
  #
  # They are the same program, and one evaluation in `tests/nimony/consteval`
  # used to disagree: the buffer handoff asserted inside nifasm's `bitabs` while
  # the file path assembled and ran it. That was nifasm reading an optional
  # operand that was not there — `Cursor.kind` past the end of a bounded scope,
  # in a buffer holding ONE foreign declaration, so the token it decoded as a
  # string was uninitialized heap. Fixed in nativenif `736b491`, which is what
  # this checkout pins; the file path only ever "worked" because its differently
  # recycled bytes did not spell a `StrLit`.
  #
  # The retry stays as the safety net it was written to be — a refusal on the
  # path with no corpus behind it should cost a few milliseconds rather than the
  # half second of a fallback to the C backend — and `viaFile` on the
  # `--verbose` line is what says it was needed. It should now never appear.
  #
  # Either way the OTHER modules are read back from their `.asm.nif` by nifasm's
  # own lazy loader, which reads only the symbols the program actually reaches.
  var sess = default(AsmSession)
  var arena = default(Arena)
  var img = default(MemImage)
  var haveArena = false
  var haveSession = false
  var laid = false
  var lastReason = ""
  let mainPool = mainAsm.code.pool
  for attempt in 0 .. 1:
    if laid: break
    if attempt == 1:
      # Nothing of the first attempt may survive into the second.
      if haveArena: releaseArena arena
      if haveSession: sess.closeSession()
      haveArena = false
      haveSession = false
      sess = default(AsmSession)
      arena = default(Arena)
      result.timings.viaFile = true
    try:
      let tAsm = getMonoTime()
      # `singleThread`: the guest's `localErr`, current-exception and allocator
      # region are all `{.threadvar.}`, and `layInMemory` REFUSES an image that
      # still has thread-locals. Evaluations are serialized, so a thread-local
      # is exactly a global here.
      if attempt == 0:
        # The pool is read BEFORE the move, exactly as `openFileSession` reads
        # it off the buffer it parsed: it is the one pool every foreign decl is
        # interned into, and it has to outlive the buffer it came from.
        sess = openSession(mainPool, backendDir, mainSuffix,
                           debugInfo = false, singleThread = true)
        haveSession = true
        sess.addMainModule(move mainAsm.code)
      else:
        # arkham again rather than a copy of the buffer above: a `TokenBuf` is
        # not copyable, the first attempt consumed it, and a second lowering of
        # one module costs a few milliseconds on a path taken once in the whole
        # corpus.
        let mainAsmFile = backendDir / mainSuffix & AsmExt
        emitAsmFor(e, mainCNif, mainAsmFile, result.timings.arkhamRuns)
        sess = openFileSession(mainAsmFile, debugInfo = false,
                               singleThread = true)
        haveSession = true
      sess.declare()
      sess.beginEmit()
      sess.emitTopLevel()
      sess.emitRoots()
      sess.finishCode()
      result.timings.assembleMs = (getMonoTime() - tAsm).inNanoseconds.float / 1e6

      # No `synthesizeProcessEntry`: that stub turns a kernel's process start
      # into a C call, and there is already a process here.
      let tLay = getMonoTime()
      arena = reserveArena()
      haveArena = true
      img = loadImage(sess.ctx, arena)
      result.timings.layMs = (getMonoTime() - tLay).inNanoseconds.float / 1e6
      laid = true
    except AsmError as ex:
      lastReason = "nifasm: " & ex.msg
    except CatchableError as ex:
      lastReason = "nifasm: " & ex.msg
    except Defect as ex:
      lastReason = "nifasm: " & ex.msg
  if not laid:
    result.reason = lastReason
    if haveArena: releaseArena arena
    if haveSession: sess.closeSession()
    return

  result.timings.codeLen = img.codeLen
  result.timings.dataLen = img.dataLen
  result.timings.externals = img.externals.len

  # ── resolve, protect, run ─────────────────────────────────────────────────
  try:
    let tBind = getMonoTime()
    var host = defaultHostSymbols()      # `exit`/`_exit` already taken over
    host.intercept("write", cast[pointer](hostWrite))
    host.intercept("kill", cast[pointer](hostKill))
    let missing = bindExternals(img, host)
    if missing.len > 0:
      result.reason = "unresolved external symbol(s): " & missing.join(", ")
      return
    makeExecutable(arena, img)
    result.timings.bindMs = (getMonoTime() - tBind).inNanoseconds.float / 1e6

    if img.entry == 0:
      result.reason = "the image has no entry point"
      return

    gIo.captured.setLen 0
    gIo.capturing = true
    let tRun = getMonoTime()
    let guest = callGuest(img, budgetMs, sourceDir)
    result.timings.runMs = (getMonoTime() - tRun).inNanoseconds.float / 1e6
    gIo.capturing = false
    result.output = gIo.captured
    gIo.captured.setLen 0

    case guest.outcome
    of goReturned, goExited:
      result.outcome = eoRan
      result.status = guest.status.int

      inc e.evaluations
    of goNotStarted:
      result.reason = "the guest thread would not start"
    of goTimedOut:
      # The guest is STILL RUNNING in this arena, on a thread nothing can stop.
      # The arena is deliberately not released, and the engine is finished for
      # the life of this process.
      result.outcome = eoBudget
      result.reason = "compile-time evaluation exceeded its budget of " &
                      $budgetMs & " ms"
      e.disabled = true
      e.disabledReason = "a previous evaluation ran past its budget and is " &
                         "still running in this process"
  except AsmError as ex:
    result.reason = "nifasm: " & ex.msg
  except CatchableError as ex:
    result.reason = "engine: " & ex.msg
  finally:
    gIo.capturing = false
    if haveSession: sess.closeSession()
    # An arena a timed-out guest is executing out of must outlive this proc.
    if haveArena and result.outcome != eoBudget: releaseArena arena
    result.timings.totalMs = (getMonoTime() - t0).inNanoseconds.float / 1e6

# ── `nimony r`: a whole program, from memory (JIT.md 7.3, JIT_IMPL.md B1) ───
#
# The second customer of the same machinery. A `const` is eight modules the
# engine lowers itself; a program is however many the user wrote, and their
# `.asm.nif` files have already been produced -- in parallel, incrementally --
# by the build graph's arkham nodes (`deps.generateFinalBuildFile`, `DoRunMem`).
# So this half starts one step later than `evaluate` does: at the main module's
# `.asm.nif`, exactly where the `link` node it replaces starts.
#
# Everything below `runWholeProgram` is deliberately inside that one proc, so
# that B3's out-of-process `nimrun` guest can replace it whole -- a pipe to a
# loader returns the same `RunResult` and `nimony.nim` never learns which one
# ran the program.

type
  RunOutcome* = enum
    roRan       ## the program ran; `status` is what it gave the shell
    roRefused   ## the engine will not run this program; `reason` says why

  RunProgram* = object
    ## Everything `runWholeProgram` needs, as one record rather than five
    ## parameters that would have to be threaded through B3's replacement too.
    backendDir*: string   ## `<nimcache>/<main>.n`, holding every `.asm.nif`
    mainModule*: string   ## the root module's suffix
    argv*: seq[string]    ## argv[0] first, then the program's own arguments
    verbose*: bool        ## print the per-stage timing line before the run

  RunResult* = object
    outcome*: RunOutcome
    status*: int
    reason*: string
    timings*: EngineTimings

const
  ThreadSpawners = ["pthread_create", "bsdthread_create", "thread_create"]
    ## JIT.md 7.1 item 7's cheap half. `singleThread` lowered every `(tvar ...)`
    ## to an ordinary global, which is only sound while the program stays
    ## single-threaded -- so a program that can create a thread must be refused
    ## rather than silently given one shared copy of what it declared as
    ## per-thread storage. Names, not a promise: the check is a scan of the
    ## image's own external symbols.
    ##
    ## It is a backstop rather than the main line. On a `nimNoLibc` target
    ## `std/rawthreads` is a `{.error.}` on everything but Linux/x86-64
    ## (`lib/std/rawthreads.nim`), so the usual answer arrives at compile time;
    ## and Linux/x86-64's own arm issues `clone(2)` inline, with no external to
    ## scan for. That gap is real and is written down in `notes/b1-nimony.md`.

type
  GuestBlocks = object
    ## The two NULL-terminated pointer arrays a C `main` is called with, and
    ## the strings they point into. One object because the strings have to
    ## outlive the pointers and both have to outlive the call; a `seq[cstring]`
    ## alone would point into temporaries.
    argStrings, envStrings: seq[string]
    argPtrs, envPtrs: seq[cstring]

proc buildGuestBlocks(p: RunProgram; g: var GuestBlocks) =
  ## argv the way a C `main` expects it, and envp reconstructed from the
  ## compiler's own environment: `nimony n` + exec hands the program the
  ## environment it inherited, and running it from memory has to hand it the
  ## same one -- `lengcgen.genMainProc` stores `envp` in `nimEnviron` and
  ## `std/envvars` reads it from there. An EMPTY block, never a null pointer:
  ## walking a null `nimEnviron` is a segfault where walking an empty one is an
  ## empty answer.
  g.argStrings = p.argv
  g.argPtrs = @[]
  for i in 0 ..< g.argStrings.len:
    g.argPtrs.add g.argStrings[i].cstring
  g.argPtrs.add nil.cstring
  g.envStrings = @[]
  for key, val in envPairs():
    g.envStrings.add key & "=" & val
  g.envPtrs = @[]
  for i in 0 ..< g.envStrings.len:
    g.envPtrs.add g.envStrings[i].cstring
  g.envPtrs.add nil.cstring

proc runTimingLine*(r: RunResult; label: string): string =
  ## `--verbose`'s one line for `nimony r`. Same columns as `timingLine`, minus
  ## arkham's (which ran in the build graph and is on nifmake's own profile) and
  ## minus the run itself, because the line is printed BEFORE the program runs.
  result = "[run-engine] " & label &
    " assemble=" & formatFloat(r.timings.assembleMs, ffDecimal, 2) &
    "ms lay=" & formatFloat(r.timings.layMs, ffDecimal, 2) &
    "ms bind=" & formatFloat(r.timings.bindMs, ffDecimal, 2) &
    "ms code=" & $r.timings.codeLen &
    "B data=" & $r.timings.dataLen &
    "B ext=" & $r.timings.externals

proc runWholeProgram*(e: var Engine; p: RunProgram): RunResult =
  ## Assemble `<backendDir>/<mainModule>.asm.nif` and everything it reaches
  ## into an arena and call `main(argc, argv, envp)` there. Never raises: a
  ## refusal is `roRefused` with a reason the driver prints.
  ##
  ## The differences from `evaluate`, and why each one:
  ##
  ## * **No output capture.** fd 1 and fd 2 are the user's terminal. The guest
  ##   writes with raw `write(2)`, so the only thing needed to keep the order
  ##   right is flushing the compiler's own buffered streams first.
  ## * **`kill` is not intercepted.** `cAbort` raises SIGABRT at `getpid()`;
  ##   under `nimony n` + exec that is what the shell reports as 134, and
  ##   in-process it is the same signal for the same reason. Taking it away
  ##   would turn an abort into a 127 the linked binary never produces, i.e.
  ##   it would make the two paths disagree -- the one thing `nimony r` must
  ##   not do. `evaluate` intercepts it for the opposite reason: there the
  ##   signal lands on a compiler that still has work to do.
  ## * **`exit` is intercepted, and needs one more name than nativenif
  ##   registers.** A native program's `main` ends in `cExit(0)`
  ##   (`lengcgen.genMainProc`), so EVERY run leaves through it, not only a
  ##   `quit`. `defaultHostSymbols` registers `exit` and `_exit`, but
  ##   `hostsyms.cName` strips one leading underscore on registration as well
  ##   as on lookup, so both land under the key `exit` -- and Mach-O's external
  ##   for C `_exit` is `__exit`, whose `cName` is `_exit`, which nobody
  ##   registered. Without the extra name the guest's exit takes the compiler
  ##   with it (measured; `notes/b1-nimony.md` §3). Registering `__exit` here
  ##   costs nothing on ELF, where the external is already covered.
  ## * **No budget.** A program the user asked to run may take as long as it
  ##   likes; there is no compiler waiting behind it.
  ## * **One parked thread per run.** `guestExit` cannot return into the
  ##   guest's frame, so the thread that called `exit` sleeps forever. A
  ##   `nimony r` process runs one program and then exits, so the leak has a
  ##   lifetime of milliseconds. It is also the reason JIT.md 7.3 wants this
  ##   out of process eventually, which is B3's `nimrun`.
  let t0 = getMonoTime()
  result = RunResult(outcome: roRefused, status: 0, reason: "")

  if e.disabled:
    result.reason = e.disabledReason
    return
  if not hostIsSupported():
    result.reason = "running a program from memory is not implemented for this host"
    return

  let mainAsm = p.backendDir / p.mainModule & AsmExt
  if not fileExists(mainAsm):
    result.reason = "the build produced no " & p.mainModule & AsmExt
    return

  var sess = default(AsmSession)
  var arena = default(Arena)
  var img = default(MemImage)
  var haveSession = false
  var haveArena = false
  try:
    let tAsm = getMonoTime()
    # `openFileSession` rather than `addMainModule`: arkham ran as build-graph
    # nodes, so the root is a file here, and nifasm's own lazy loader opens the
    # other modules out of the same directory by suffix -- the same thing the
    # `link` node this replaces does with `(input 0 0)`.
    #
    # `singleThread`: `layInMemory` REFUSES an image that still carries
    # thread-locals, because a loaded image has no thread-local mechanism of
    # its own. The refusal is the loud failure; `ThreadSpawners` below is the
    # other half of the same promise.
    sess = openFileSession(mainAsm, debugInfo = false, singleThread = true)
    haveSession = true
    sess.declare()
    sess.beginEmit()
    sess.emitTopLevel()
    sess.emitRoots()
    sess.finishCode()
    result.timings.assembleMs = (getMonoTime() - tAsm).inNanoseconds.float / 1e6

    # No `synthesizeProcessEntry`: that stub turns a kernel's process start
    # into a C call, and there is already a process here.
    let tLay = getMonoTime()
    arena = reserveArena()
    haveArena = true
    img = loadImage(sess.ctx, arena)
    result.timings.layMs = (getMonoTime() - tLay).inNanoseconds.float / 1e6
  except AsmError as ex:
    result.reason = "nifasm: " & ex.msg
  except CatchableError as ex:
    result.reason = "nifasm: " & ex.msg
  except Defect as ex:
    result.reason = "nifasm: " & ex.msg
  if result.reason.len > 0:
    if haveArena: releaseArena arena
    if haveSession: sess.closeSession()
    return

  result.timings.codeLen = img.codeLen
  result.timings.dataLen = img.dataLen
  result.timings.externals = img.externals.len

  try:
    let tBind = getMonoTime()
    for ext in img.externals:
      for spawner in ThreadSpawners:
        if ext.extName == spawner or ext.extName == "_" & spawner:
          result.reason = "the program creates threads (" & ext.extName &
            "), and running from memory lowers every thread-local to a global"
          return
    var host = defaultHostSymbols()
    host.intercept("__exit", cast[pointer](guestExit))
    let missing = bindExternals(img, host)
    if missing.len > 0:
      result.reason = "unresolved external symbol(s): " & missing.join(", ")
      return
    makeExecutable(arena, img)
    result.timings.bindMs = (getMonoTime() - tBind).inNanoseconds.float / 1e6

    if img.entry == 0:
      result.reason = "the image has no entry point (no `main.0`)"
      return

    if p.verbose:
      # BEFORE the run, not after: everything the program writes belongs to the
      # program, and a compiler line in the middle of it would be the compiler
      # lying about whose output that is. On stderr, and for the same reason:
      # `nimony r prog.nim > out` must put the PROGRAM's stdout in `out`.
      stderr.writeLine runTimingLine(result, p.mainModule)

    # The guest writes with raw `write(2)` while the compiler's own streams are
    # buffered, so anything still sitting in them would surface AFTER the
    # program's first line. Flush, then hand over.
    flushFile stdout
    flushFile stderr

    var blocks = GuestBlocks(argStrings: @[], envStrings: @[],
                             argPtrs: @[], envPtrs: @[])
    buildGuestBlocks(p, blocks)
    let tRun = getMonoTime()
    let guest = runImage(img, blocks.argStrings.len.cint, addr blocks.argPtrs[0],
                         addr blocks.envPtrs[0], budgetMs = 0)
    result.timings.runMs = (getMonoTime() - tRun).inNanoseconds.float / 1e6

    case guest.outcome
    of goReturned, goExited:
      result.outcome = roRan
      result.status = guest.status.int
    of goNotStarted:
      result.reason = "the guest thread would not start"
    of goTimedOut:
      # Unreachable: no budget was passed, so the wait has no deadline to miss.
      # Spelled out rather than elided so the arm is already here when B4 wants
      # one.
      result.reason = "the program ran past a budget it was not given"
  except AsmError as ex:
    result.reason = "nifasm: " & ex.msg
  except CatchableError as ex:
    result.reason = "engine: " & ex.msg
  finally:
    if haveSession: sess.closeSession()
    # The arena is NOT released: the guest's exit parked a thread inside it,
    # and on any other outcome the program's own memory may still be reachable
    # from that thread. A `nimony r` process ends a few milliseconds later.
    result.timings.totalMs = (getMonoTime() - t0).inNanoseconds.float / 1e6

proc timingLine*(r: EngineResult; label: string): string =
  ## One line for `--verbose`: where the milliseconds went, and how big the
  ## image was. Written by hand rather than through `strformat` so the columns
  ## do not move between a hit and a miss.
  result = "[ctfe-engine] " & label &
    " arkham=" & formatFloat(r.timings.arkhamMs, ffDecimal, 2) &
    "ms (" & $r.timings.arkhamRuns & " run, " & $r.timings.cacheHits & " cached, " & $r.timings.modules & " modules)" &
    " assemble=" & formatFloat(r.timings.assembleMs, ffDecimal, 2) &
    "ms lay=" & formatFloat(r.timings.layMs, ffDecimal, 2) &
    "ms bind=" & formatFloat(r.timings.bindMs, ffDecimal, 2) &
    "ms run=" & formatFloat(r.timings.runMs, ffDecimal, 2) &
    "ms total=" & formatFloat(r.timings.totalMs, ffDecimal, 2) &
    "ms code=" & $r.timings.codeLen &
    "B data=" & $r.timings.dataLen &
    "B ext=" & $r.timings.externals &
    (if r.timings.viaFile: " viaFile" else: "")
