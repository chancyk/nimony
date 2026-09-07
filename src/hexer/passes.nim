#
#
#           Hexer Compiler
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

when not defined(nimony):
  import std/[monotimes, times, syncio, os, strutils]
import ../lib/[nifpools]

type
  Pass* = object
    n*: Cursor         ## Current read position in buf
    buf*: TokenBuf     ## Input buffer for current pass
    dest*: TokenBuf    ## Output buffer being written to
    moduleSuffix*: string  ## Module suffix for symbol generation
    bits*: int         ## number of bits in the target architecture
    nextTemp*: int     ## Counter for temporary variable generation
    passName*: string  ## Current pass name (for debugging/logging)
    when not defined(nimony):
      passStart*: MonoTime  ## start time of current pass (only set when timing on)

when not defined(nimony):
  # Per-pass timing log: append one line per (module, pass) when
  # `NIMONY_PASS_TIMING=<file>` is set in the environment. Multiple hexer
  # processes can append to the same file in parallel — lines are short and
  # `O_APPEND` makes single `write(2)` calls atomic on POSIX, so the log
  # stays well-formed without locking. Each line is `<module>\t<pass>\t<sec>`.
  var
    passTimingInited: bool
    passTimingLog: File
    passTimingEnabled: bool

  proc ensurePassTimingInit() =
    if passTimingInited: return
    passTimingInited = true
    let env = getEnv("NIMONY_PASS_TIMING")
    if env.len == 0: return
    try:
      passTimingLog = open(env, fmAppend)
      passTimingEnabled = true
    except IOError:
      discard

  proc logPassTiming(moduleSuffix, passName: string; start: MonoTime) =
    if not passTimingEnabled: return
    let sec = float(inMicroseconds(getMonoTime() - start)) / 1_000_000.0
    # Pre-build the line so a single write(2) covers it — keeps parallel
    # appenders from interleaving fragments.
    let line = moduleSuffix & '\t' & passName & '\t' &
               sec.formatFloat(ffDecimal, 6) & '\n'
    passTimingLog.write line
    passTimingLog.flushFile()

proc initPass*(initialBuf: sink TokenBuf; moduleSuffix: string;
               firstPassName: string; bits: int; nextTemp = 0): Pass =
  ## Initialize a new Pass pipeline with the given input buffer.
  ## The buffer is moved into the Pass and a cursor is created.
  ## `nextTemp` seeds the xelim temp counter: a NESTED pipeline (e.g. the
  ## per-coroutine Final-IR run in `treIteratorBody`) must continue the outer
  ## pipeline's counter, or its `lowerExprs` re-mints \`x.N SymIds that
  ## collide with still-live outer temps in the same proc (one frame slot,
  ## two types — see tests/nimony/cps/tifexpr_arg_temp_collision.nim).
  when not defined(nimony):
    ensurePassTimingInit()
  result = Pass(buf: initialBuf, moduleSuffix: moduleSuffix, bits: bits, nextTemp: nextTemp, passName: firstPassName)
  result.n = beginRead(result.buf)
  result.dest = createTokenBuf(300)
  when not defined(nimony):
    if passTimingEnabled:
      result.passStart = getMonoTime()

proc prepareForNext*(pass: var Pass; nextPassName: string) =
  ## Transition to the next pass in the pipeline.
  when defined(logPasses):
    echo pass.passName, " produced:"
    echo "  ", toString(pass.dest, false)

  when not defined(nimony):
    if passTimingEnabled:
      logPassTiming(pass.moduleSuffix, pass.passName, pass.passStart)

  # End reading from old buffer

  # Swap: previous output becomes next input
  swap(pass.buf, pass.dest)
  pass.dest.shrink 0
  pass.n = beginRead(pass.buf)

  pass.passName = nextPassName
  when not defined(nimony):
    if passTimingEnabled:
      pass.passStart = getMonoTime()

proc finishPass*(pass: var Pass) =
  ## Log the final pass's elapsed time. Call once after the last pass body
  ## has finished; no-op when timing is disabled.
  when defined(logPasses):
    echo pass.passName, " produced:"
    echo "  ", toString(pass.dest, false)

  when not defined(nimony):
    if passTimingEnabled:
      logPassTiming(pass.moduleSuffix, pass.passName, pass.passStart)

# ── Stage timing for the parts of `expand` that are not pipeline passes ────
#
# The eleven passes above account for 153 ms of the 275 ms `hexer c` spends on
# `src/nimony/sem.nim`; the rest is spread over the parse, `trToplevel`, the
# two whole-module analyses (`funcsummary`, `intraModuleInline`), the
# declaration digests, the serialize and the writes. B3b's question is which
# of those a declaration-level lowering could skip, and that cannot be
# answered without measuring them separately -- `notes/b3b.md` section 4 had
# to do it with temporary probes that were then reverted, so the next attempt
# started by rebuilding them. This is the same instrument, kept.
#
# It rides the `NIMONY_PASS_TIMING=<file>` channel the passes already use, and
# prefixes every stage with `|` so a reader can tell a pipeline pass from a
# stage of `expand`. Off unless that variable is set, and one `getMonoTime`
# per stage per module when it is.

type
  StageTimer* = object
    ## Threaded through `expand` explicitly rather than kept in a global, and
    ## carried as a value so a nested run (`optimizeLengOutput`) can hold its
    ## own without disturbing its caller's.
    module*: string
    when not defined(nimony):
      start: MonoTime
      on: bool

proc startStages*(module: string): StageTimer =
  ## Begin timing the stages of one module's lowering.
  result = StageTimer(module: module)
  when not defined(nimony):
    ensurePassTimingInit()
    result.on = passTimingEnabled
    if result.on: result.start = getMonoTime()

proc restart*(t: var StageTimer) =
  ## Drop the elapsed time without logging it -- used after a nested run that
  ## logged its own stages, so the next stage is not charged for it too.
  when not defined(nimony):
    if t.on: t.start = getMonoTime()

proc note*(t: var StageTimer; stage: string) =
  ## Log the time since the previous `note`/`startStages`/`restart` under
  ## `stage`, then start the next stage.
  when not defined(nimony):
    if t.on:
      logPassTiming(t.module, "|" & stage, t.start)
      t.start = getMonoTime()
