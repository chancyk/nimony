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

import ".." / lib / [nifcore, nifcoreparse, nifchecksums, tooldirs]
import guestwire

import arkham / generate
import arkham / core / lengdecl
import nifasm / [driver, hostrun, blobcache]
import nifasm / core / [hostsyms, asmerror, asmprofile]
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
    emitRootsMs*: float
      ## The reachability worklist alone, out of `assembleMs`. B3 measured it at
      ## 96.7 % of a cold link of the compiler, so it is the one sub-stage worth
      ## a column: everything a code cache can do, it does here.
    blobCache*: bool         ## the per-symbol code cache was on for this run
    blobHits*, blobStale*, blobRecorded*: int
      ## nifasm's own counters, read off the session after `finishCode`. `hits`
      ## are the fragments replayed, `stale` the ones a validity check rejected,
      ## `recorded` the ones this run wrote back. A warm link is all hits; a
      ## cold one is all recorded; an edit is the shape in between, and reading
      ## the three together is how a cache that quietly stopped working shows
      ## up as a number rather than as a slow afternoon.

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
    profile*: bool
      ## also let nifasm print its own per-stage table (`asmprofile`): every
      ## stage with its wall time and count, plus the per-module emit cost.
      ## `--profile` on `nimony r`; `--verbose` implies it, because the numbers
      ## a reader of the timing line wants next are always in that table.
    blobCacheDir*: string
      ## `deps.blobCacheDir(config)`, or "" when the cache is off. The SAME
      ## directory the `link` node passes to nifasm as `--blobcache:` -- one
      ## store per nimcache, holding both paths' fragments under their own
      ## flag keys (`deps.blobCacheDir` says why they cannot be one set).
      ## Empty is not an error: `useBlobCache` returns on an empty string and
      ## the session assembles from scratch, which is the `--no-blobcache`
      ## behaviour and the pre-B3 one.
    dev*: bool
      ## `nimony dev`: the program is expected to be long-lived and to reach a
      ## SAFEPOINT by calling `nimony_dev_poll` (`lib/std/devreload.nim`).
      ## `runWholeProgram` itself does nothing with this -- the loader passes
      ## the intercept that answers that call -- but it travels in the record
      ## because it is a property of the RUN, and `nimony dev` and `nimony r`
      ## reach the loader through the same one.

  LoadedHook* = proc (ctx: pointer; arena: Arena; img: MemImage): string {.nimcall.}
    ## Called once, after the image is laid out, bound and made executable, and
    ## BEFORE the guest is started. "" lets the run proceed; anything else
    ## refuses it with that as the reason.
    ##
    ## A proc pointer plus an explicit context pointer rather than a closure
    ## (AGENTS.md), and a hook rather than an out-parameter because the caller
    ## that needs this needs it while `runWholeProgram` is still running: hot
    ## reload has to have the arena and the image before the guest's first
    ## instruction, since the guest may reach its first safepoint immediately.

  HostIntercept* = object
    ## One name the caller wants to answer itself, ahead of the arena and the
    ## host process (`nifasm/core/hostsyms`'s first tier). A record rather than
    ## a tuple so the two fields are named at every call site: `fn` is a C
    ## function pointer and nothing checks its signature.
    name*: string
    fn*: pointer

  RunResult* = object
    outcome*: RunOutcome
    status*: int
    reason*: string
    signal*: int
      ## Non-zero only on the out-of-process path, and only when the guest died
      ## from a signal: in-process there is nothing to report, because the
      ## signal landed on the compiler itself and the compiler was already gone
      ## when it did. The caller re-raises it (`guestwire.reraiseAsGuestDid`) so
      ## that both paths hand the shell the same WAIT STATUS rather than merely
      ## the same number.
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
  ##
  ## `emitRoots` and the three blob-cache counters are here rather than only in
  ## nifasm's `--profile` table because they are the ANSWER to "why was this run
  ## the length it was": `assemble` is `emitRoots` plus small change, and
  ## `emitRoots` is `stale` fragments re-selected while `hits` were spliced.
  result = "[run-engine] " & label &
    " assemble=" & formatFloat(r.timings.assembleMs, ffDecimal, 2) &
    "ms emitRoots=" & formatFloat(r.timings.emitRootsMs, ffDecimal, 2) &
    "ms lay=" & formatFloat(r.timings.layMs, ffDecimal, 2) &
    "ms bind=" & formatFloat(r.timings.bindMs, ffDecimal, 2) &
    "ms code=" & $r.timings.codeLen &
    "B data=" & $r.timings.dataLen &
    "B ext=" & $r.timings.externals
  if r.timings.blobCache:
    result.add " blobcache=on hits=" & $r.timings.blobHits &
      " stale=" & $r.timings.blobStale &
      " recorded=" & $r.timings.blobRecorded
  else:
    result.add " blobcache=off"

proc runWholeProgram*(e: var Engine; p: RunProgram;
                      extra: openArray[HostIntercept] = [];
                      onLoaded: LoadedHook = nil;
                      onLoadedCtx: pointer = nil): RunResult =
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
  ## * **`exit` is intercepted, and `defaultHostSymbols` is now enough.** A
  ##   native program's `main` ends in `cExit(0)` (`lengcgen.genMainProc`), so
  ##   EVERY run leaves through it, not only a `quit`. B1 had to register
  ##   `__exit` by hand here: `hostsyms.cName` stripped one leading underscore
  ##   on registration as well as on lookup, so `intercept("exit")` and
  ##   `intercept("_exit")` both landed under the key `exit` while Mach-O's
  ##   external for C `_exit` -- `__exit` -- asked for the key `_exit`, which
  ##   nobody had. The guest's exit then took the compiler with it (measured;
  ##   `notes/b1-nimony.md` §3). Fixed upstream in nativenif `f8d2676`, which
  ##   `src/nativenif.commit` pins, so the workaround is gone and the two
  ##   registrations `defaultHostSymbols` makes are the whole story.
  ## * **No budget.** A program the user asked to run may take as long as it
  ##   likes; there is no compiler waiting behind it.
  ## * **One parked thread per run.** `guestExit` cannot return into the
  ##   guest's frame, so the thread that called `exit` sleeps forever. A
  ##   `nimony r` process runs one program and then exits, so the leak has a
  ##   lifetime of milliseconds. It is also the reason JIT.md 7.3 wants this
  ##   out of process eventually. B3 shipped its code cache and left the
  ##   `nimrun` guest for B4, because nothing measured asks for it while a
  ##   `nimony r` process still runs one program and exits; `nimony dev`,
  ##   which re-runs without a fresh compiler, is what will.
  let t0 = getMonoTime()
  result = RunResult(outcome: roRefused, status: 0, reason: "")
  if p.profile:
    # Before anything else: `asmprofile` decides whether to take a timestamp at
    # every stage entry, and `openFileSession` is already one of them.
    enableProfiling()

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
    # `nimony dev` walks the guest's stack at a safepoint to find out whether a
    # frame of a proc it is about to replace is live, and only the trace table
    # says which proc a return address belongs to. Nothing in the guest
    # references `arkham.traceinfo.0`, so the table has to be asked for
    # (`AsmSession.wantTraceTable`). Before `beginEmit`, which is where it is
    # read. A `nimony r` carries none of it.
    sess.wantTraceTable = p.dev
    # Before `declare`, which is where the target becomes known and the cache
    # key is minted (`driver.useBlobCache`). An empty directory string is the
    # documented way to say "no cache" and returns without touching anything,
    # so `--no-blobcache` needs no second branch here.
    sess.useBlobCache(p.blobCacheDir)
    result.timings.blobCache = p.blobCacheDir.len > 0
    sess.declare()
    sess.beginEmit()
    sess.emitTopLevel()
    let tRoots = getMonoTime()
    sess.emitRoots()
    result.timings.emitRootsMs = (getMonoTime() - tRoots).inNanoseconds.float / 1e6
    sess.finishCode()
    # Written BEFORE the guest runs, not after: `guestExit` parks the thread
    # that called it and a program is free to take as long as it likes, so a
    # flush at the end of the proc would be a flush that a `nimony r` of a
    # long-running program never reaches.
    sess.saveBlobCache()
    result.timings.blobHits = sess.bc.hits
    result.timings.blobStale = sess.bc.stale
    result.timings.blobRecorded = sess.bc.recorded
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
    # `extra` before `bindExternals`, and it wins over the arena and the host
    # process because `hostsyms` puts intercepts first -- which is what makes a
    # SAFEPOINT possible at all: `nimony dev` answers the guest's
    # `nimony_dev_poll` here, and the answer runs ON THE GUEST'S THREAD, in a
    # frame the guest called into. That is the synchronous seed `notes/b4.md`
    # 1a says the trace-table walk has to have.
    for it in extra: host.intercept(it.name, it.fn)
    let missing = bindExternals(img, host)
    if missing.len > 0:
      result.reason = "unresolved external symbol(s): " & missing.join(", ")
      return
    makeExecutable(arena, img)
    result.timings.bindMs = (getMonoTime() - tBind).inNanoseconds.float / 1e6

    if img.entry == 0:
      result.reason = "the image has no entry point (no `main.0`)"
      return

    if onLoaded != nil:
      # After `makeExecutable`, before the guest exists. `nimony dev` builds its
      # reload session here: the arena, the live image and its trace table are
      # all final now, and the guest may reach its first safepoint before this
      # proc's next statement would have run.
      let refusal = onLoaded(onLoadedCtx, arena, img)
      if refusal.len > 0:
        result.reason = refusal
        return

    if p.verbose or p.profile:
      # BEFORE the run, not after: everything the program writes belongs to the
      # program, and a compiler line in the middle of it would be the compiler
      # lying about whose output that is. On stderr, and for the same reason:
      # `nimony r prog.nim > out` must put the PROGRAM's stdout in `out`.
      stderr.writeLine runTimingLine(result, p.mainModule)
    if p.profile:
      # nifasm's own table, on stderr too, and for the same reason. It is the
      # detail behind the line above: every stage with its count, the blob
      # read/write rows, and the per-module emit cost that says WHICH module an
      # edit made expensive.
      profReport(p.mainModule & AsmExt)

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

# ── the out-of-process guest ────────────────────────────────────────────────
#
# `runWholeProgram` maps the arena in THIS process. That is right for `nimony
# r`, which runs one program and exits, and it is what `nimony dev` cannot do:
# `hostrun.guestExit` parks the thread that called `exit` forever (there is no
# way back out of a guest frame), so the arena can never be released and every
# run leaks a thread. JIT.md 7.3's answer is a loader process -- and this is
# the compiler's half of it. `src/nimony/nimrun.nim` is the other half, and it
# calls the very proc above, so the two paths are one implementation with a
# `posix_spawn` in the middle rather than two that have to be kept in step.

proc encodeRunRequest(p: RunProgram): seq[string] =
  ## `RunProgram` -> the `run` record `nimrun.decodeRun` reads back. Positional
  ## and flat: the argument vector is last and preceded by its own count, so a
  ## program argument may contain anything at all.
  var flags = ""
  if p.verbose: flags.add 'v'
  if p.profile: flags.add 'p'
  if p.dev: flags.add 'd'
  result = @["run", p.backendDir, p.mainModule, p.blobCacheDir, flags,
             $p.argv.len]
  for a in p.argv: result.add a

proc applyTiming(t: var EngineTimings; pair: string) =
  ## One `key=value` of a reply. An unknown key is IGNORED on purpose: the
  ## timings are diagnostics, and a `nimrun` that learned a new column must not
  ## make an older compiler refuse a run that worked.
  let eq = pair.find('=')
  if eq <= 0: return
  let key = pair[0 ..< eq]
  let val = pair[eq+1 .. ^1]
  var f = 0.0
  var i = 0
  try:
    f = parseFloat(val)
    i = int(f)
  except ValueError:
    return
  case key
  of "assembleMs": t.assembleMs = f
  of "emitRootsMs": t.emitRootsMs = f
  of "layMs": t.layMs = f
  of "bindMs": t.bindMs = f
  of "runMs": t.runMs = f
  of "totalMs": t.totalMs = f
  of "codeLen": t.codeLen = i
  of "dataLen": t.dataLen = i
  of "externals": t.externals = i
  of "blobCache": t.blobCache = val == "1"
  of "blobHits": t.blobHits = i
  of "blobStale": t.blobStale = i
  of "blobRecorded": t.blobRecorded = i
  else: discard

proc runWholeProgramOutOfProcess*(p: RunProgram): RunResult =
  ## Run `p` in a `nimrun` process and report what it said. Never raises; a
  ## refusal is `roRefused` with a reason, exactly as in-process.
  ##
  ## The three things this arrangement is FOR, each visible in the code below:
  ##
  ## * the compiler keeps no arena and no parked thread -- both die with the
  ##   loader, which is what makes running many programs from one compiler
  ##   process possible at all;
  ## * a guest that faults kills the loader and nothing else. `reapGuest`
  ##   reports it as `gxSignalled`, and the caller decides whether the shell
  ##   should see the same wait status (`nimony r`: yes) or a diagnostic
  ##   (`nimony dev`: a restart);
  ## * descriptors 0, 1 and 2 were never touched, so the program's output is
  ##   the user's terminal with nothing in between -- the reason the two paths
  ##   are byte-identical rather than argued to be.
  result = RunResult(outcome: roRefused, status: 0, reason: "", signal: 0)
  let exe = findTool("nimrun")
  if not fileExists(exe):
    result.reason = "there is no `nimrun` in " & binDir() &
      "; build it with `hastur build all`"
    return
  # The loader inherits our stdout and stderr, so anything still in our buffers
  # would surface after the program's first line. Same flush, same reason, as
  # the in-process path.
  flushFile stdout
  flushFile stderr
  var launch = GuestLaunch(pid: 0, chan: openChannel(-1), alive: false)
  let spawnErr = spawnGuest(exe, [], launch)
  if spawnErr.len > 0:
    result.reason = spawnErr
    return

  var fields: seq[string] = @[]
  if not launch.chan.recvFields(fields) or fields.len < 2 or
     fields[0] != "hello":
    closeChannel launch
    discard reapGuest(launch)
    result.reason = "`nimrun` did not answer the handshake (" & exe & ")"
    return
  if fields[1] != $GuestProtocolVersion:
    closeChannel launch
    discard reapGuest(launch)
    result.reason = "`nimrun` speaks guest protocol " & fields[1] &
      " and this compiler speaks " & $GuestProtocolVersion &
      "; rebuild the toolchain"
    return

  if not launch.chan.sendFields(encodeRunRequest(p)):
    closeChannel launch
    discard reapGuest(launch)
    result.reason = "`nimrun` closed the control channel before the request"
    return

  let answered = launch.chan.recvFields(fields)
  closeChannel launch
  let ended = reapGuest(launch)

  if not answered:
    # No reply: the loader died mid-run. A signal is the interesting case and
    # is reported as such, because it is what an aborting or faulting program
    # looks like from out here -- and it is a RESULT, not an engine failure.
    case ended.kind
    of gxSignalled:
      result = RunResult(outcome: roRan, status: 128 + ended.signal,
                         reason: "", signal: ended.signal)
    of gxExited:
      result.reason = "`nimrun` exited " & $ended.code & " without an answer"
    of gxUnknown:
      result.reason = "`nimrun` disappeared without an answer"
    return

  if fields.len < 3:
    result.reason = "`nimrun` answered with " & $fields.len & " fields"
    return
  var status = 0
  for ch in fields[1]:
    if ch in {'0' .. '9'}: status = status * 10 + (ord(ch) - ord('0'))
  result.status = status
  result.reason = fields[2]
  for i in 3 ..< fields.len: applyTiming(result.timings, fields[i])
  result.outcome = (if fields[0] == "ran": roRan else: roRefused)

# ── the guest as a long-lived process (`nimony dev`) ────────────────────────
#
# `runWholeProgramOutOfProcess` is the one-shot: spawn, send, wait, reap. Hot
# reload needs the three steps taken apart, because the interesting part happens
# BETWEEN them -- the compiler rebuilds while the guest is still running and
# then asks it to swap. What travels is the same framing and the same loader;
# only the record verbs are new.

type
  DevGuest* = object
    ## A `nimrun` running a program that has not finished. One object because
    ## the process and the channel are useless apart and both have to be
    ## released.
    launch*: GuestLaunch
    running*: bool
    finished*: bool
    final*: RunResult

  SwapReply* = enum
    srSwapped     ## the code is in
    srDeferred    ## a replaced proc has a live frame; ask again
    srFailed      ## the loader refused; `reason`
    srGone        ## the guest ended instead of answering

proc startDevGuest*(p: RunProgram; g: var DevGuest): string =
  ## Spawn a loader, hand it the program, and RETURN -- the guest is running
  ## when this comes back. "" on success.
  g = DevGuest(launch: GuestLaunch(pid: 0, chan: openChannel(-1), alive: false),
               running: false, finished: false,
               final: RunResult(outcome: roRefused, status: 0, reason: "",
                                signal: 0))
  let exe = findTool("nimrun")
  if not fileExists(exe):
    return "there is no `nimrun` in " & binDir() &
      "; build it with `hastur build all`"
  flushFile stdout
  flushFile stderr
  let spawnErr = spawnGuest(exe, [], g.launch)
  if spawnErr.len > 0: return spawnErr
  var fields: seq[string] = @[]
  if not g.launch.chan.recvFields(fields) or fields.len < 2 or
     fields[0] != "hello":
    closeChannel g.launch
    discard reapGuest(g.launch)
    return "`nimrun` did not answer the handshake"
  if fields[1] != $GuestProtocolVersion:
    closeChannel g.launch
    discard reapGuest(g.launch)
    return "`nimrun` speaks guest protocol " & fields[1] &
      " and this compiler speaks " & $GuestProtocolVersion
  if not g.launch.chan.sendFields(encodeRunRequest(p)):
    closeChannel g.launch
    discard reapGuest(g.launch)
    return "`nimrun` closed the control channel before the request"
  g.running = true
  result = ""

proc takeFinal(g: var DevGuest; fields: seq[string]) =
  ## A `ran`/`refused` record: the program is over.
  g.finished = true
  g.running = false
  var status = 0
  if fields.len > 1:
    for ch in fields[1]:
      if ch in {'0' .. '9'}: status = status * 10 + (ord(ch) - ord('0'))
  g.final = RunResult(
    outcome: (if fields[0] == "ran": roRan else: roRefused),
    status: status,
    reason: (if fields.len > 2: fields[2] else: ""), signal: 0)
  for i in 3 ..< fields.len: applyTiming(g.final.timings, fields[i])

proc reapDevGuest*(g: var DevGuest) =
  ## Collect the process. Sets `final.signal` when it died from one, so the
  ## caller can say `restart: the program crashed (SIGSEGV)` instead of a bare
  ## number.
  if not g.launch.alive: return
  closeChannel g.launch
  let ended = reapGuest(g.launch)
  g.running = false
  if not g.finished:
    g.finished = true
    case ended.kind
    of gxSignalled:
      g.final = RunResult(outcome: roRan, status: 128 + ended.signal,
                          reason: "", signal: ended.signal)
    of gxExited:
      g.final = RunResult(outcome: roRan, status: ended.code, reason: "",
                          signal: 0)
    of gxUnknown:
      g.final = RunResult(outcome: roRefused, status: 0,
                          reason: "the guest disappeared", signal: 0)

proc stopDevGuest*(g: var DevGuest) =
  ## End the program. `SIGTERM`, then reap.
  ##
  ## This is the half of JIT.md 7.4's *"or restart the guest"* that only a
  ## process boundary can do: there is no way to stop a guest THREAD from
  ## outside (`hostrun.nim`'s header -- the three ways out of a foreign frame
  ## are `longjmp`, unwinding and not leaving), which is why an in-process
  ## `nimony dev` could never restart a program it had decided to replace.
  if g.launch.alive and g.launch.pid > 0:
    discard signalGuest(g.launch, guestTermSignal())
  reapDevGuest g

proc pollDevGuest*(g: var DevGuest): bool =
  ## Has the program ended? Non-blocking; true once `final` is filled in.
  if g.finished: return true
  if not g.launch.alive: return false
  if g.launch.chan.hasPending():
    var fields: seq[string] = @[]
    if g.launch.chan.recvFields(fields) and fields.len > 0 and
       (fields[0] == "ran" or fields[0] == "refused"):
      takeFinal(g, fields)
      reapDevGuest g
      return true
    # The channel broke, or the loader said something unexpected while nothing
    # was asked of it: either way the program is not answering any more.
    reapDevGuest g
    return true
  result = false

proc askSwap*(g: var DevGuest; backendDir, mainModule, blobCacheDir: string;
              changed: seq[string]; reason, stack: var string;
              generation: var int): SwapReply =
  ## Send a `swap` and block until the loader answers it — which happens at the
  ## guest's next safepoint, i.e. its next `devPoll()`.
  ##
  ## Blocking is right here and nowhere else: the compiler has nothing to do
  ## until it knows whether the code went in, and a program that never reaches a
  ## safepoint has told the user something worth waiting to find out. A guest
  ## that ENDS instead of answering is `srGone`, not a hang, because the loader
  ## sends its final record on the same channel.
  reason = ""
  stack = ""
  if not g.running: return srGone
  var req = @["swap", backendDir, mainModule, blobCacheDir, $changed.len]
  for c in changed: req.add c
  if not g.launch.chan.sendFields(req):
    reapDevGuest g
    return srGone
  while true:
    var fields: seq[string] = @[]
    if not g.launch.chan.recvFields(fields):
      reapDevGuest g
      return srGone
    if fields.len == 0: continue
    case fields[0]
    of "swapped", "deferred", "failed":
      if fields.len > 1:
        var v = 0
        for ch in fields[1]:
          if ch in {'0' .. '9'}: v = v * 10 + (ord(ch) - ord('0'))
        generation = v
      if fields.len > 2: reason = fields[2]
      if fields.len > 3: stack = fields[3]
      return (if fields[0] == "swapped": srSwapped
              elif fields[0] == "deferred": srDeferred
              else: srFailed)
    of "ran", "refused":
      takeFinal(g, fields)
      reapDevGuest g
      return srGone
    else: discard
