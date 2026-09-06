#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The Leng engine behind compile-time evaluation (`--ctfe:engine`, JIT.md 7.2).
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
  # They should be the same program and are not always: one evaluation in
  # `tests/nimony/consteval` (`tconstfloat`'s first, and only when its nimcache
  # already holds other tests' artifacts) makes the buffer handoff assert inside
  # nifasm's `bitabs` while the file path assembles it and runs it correctly.
  # Retrying through the tested path costs a few milliseconds on an evaluation
  # that would otherwise have fallen back to the C backend and cost half a
  # second, and it keeps the difference visible instead of hiding it: the
  # `--verbose` line says `viaFile`. See notes/b2.md for what is known about it.
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
