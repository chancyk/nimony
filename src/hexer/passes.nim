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
import std/tables
import ../lib/[nifpools, symparser]

# ── Declaration-scoped names for synthesized symbols ───────────────────────
#
# Every counter hexer used to mint a temporary from was module-wide, so the
# name a declaration's temps got depended on how many temps the declarations
# BEFORE it needed -- and, because `lowerExprs` runs over the whole buffer more
# than once sharing one counter, on how many the declarations AFTER it needed
# too.
# An edit to the last proc of a module renamed the first proc's `\`x.0` to
# `\`x.1` (`notes/b3b.md` section 11). That makes a declaration-level diff of
# the lowering output meaningless, which is what B3b's splice is built on.
#
# `TempNamer` is F1's fix one level down (`notes/f1.md` section 4): the counter
# is keyed by (identifier, owning declaration) and the owner's name rides in
# the disambiguator, so the string is unique in the module without the number
# being a function of the module.
#
#     `x`semStmt`0.3            a local  (one dot, `symparser.isLocalName`)
#     `setlit`semStmt`0.0.mymod a global (two dots, module suffix last)
#
# The namespace rides in the IDENTIFIER, ahead of the dot: a NIF symbol's
# disambiguator carries a number and nothing else (#2457, `notes/f1-respell.md`).
#
# The table is PERSISTENT per owner rather than pushed and popped: `lowerExprs`
# visits the same routine more than once (xelim1, xelim_final, and one nested
# Final-IR run per coroutine) and a counter that restarted at 0 would hand the
# second visit names the first one already minted -- `pool.syms` is
# identity-by-name, so that is one SymId for two distinct temps.

type
  TempNamer* = object
    ns*: string
      ## Namespace segment of the declaration currently being lowered, empty
      ## at module level (top-level statements, which all land in one
      ## `initBody` anyway and have no declaration identity to be stable for).
    counters*: Table[string, int]
      ## (identifier + namespace) -> last number handed out.

proc localNamespaceOf*(sym: SymId): string =
  ## The namespace segment for the temporaries of the declaration `sym`: its
  ## module-less name with the dots written as `` ` `` so a local built from it
  ## keeps exactly ONE dot. `semStmt.0.mymod` -> `` semStmt`0 ``.
  ## A missing symbol yields the empty namespace, i.e. today's module-wide
  ## numbering — a declaration that has no name has no identity to be stable
  ## for either.
  if sym == SymId(0): return ""
  result = removeModule(pool.symString(sym))
  for i in 0 ..< result.len:
    if result[i] == '.': result[i] = LocalNsSep

proc toplevelNamespace*(n: Cursor): string =
  ## The namespace for the symbols synthesized while lowering the top-level
  ## statement `n`. Every declaration node spells its own name as its first
  ## child; a bare statement (module init code) has none and keeps the
  ## module-wide numbering it always had.
  if n.isTagLit and n.childCursor.isSymbolDef:
    result = localNamespaceOf(n.childCursor.symId)
  else:
    result = ""

proc nextNumber*(t: var TempNamer; base: string): int =
  var key = base
  if t.ns.len > 0:
    key.add LocalNsSep
    key.add t.ns
  var counter = addr t.counters.mgetOrPut(key, -1)
  counter[] += 1
  result = counter[]

proc freshName*(t: var TempNamer; base: string): string =
  ## A local-layout name: `` \`x `` -> `` \`x`semStmt`0.3 ``.
  localSymName(base, nextNumber(t, base), t.ns)

proc freshSym*(t: var TempNamer; base: string): SymId =
  pool.symId(freshName(t, base))

proc freshGlobalName*(t: var TempNamer; base, moduleSuffix: string): string =
  ## A global-layout name: the module suffix stays the LAST dotted segment, so
  ## `extractModule` and `isInstantiation` still read it the way they always
  ## did — `` `setlit`semStmt`0.0.mymod ``, the shape upstream's own
  ## `` write`sys.0.<module> `` uses. The namespace is inside the identifier,
  ## so this reads back with a NUMERIC disambiguator like every other symbol
  ## (#2457); before the respelling it did not.
  result = freshName(t, base)
  result.add '.'
  result.add moduleSuffix

proc freshGlobalSym*(t: var TempNamer; base, moduleSuffix: string): SymId =
  pool.symId(freshGlobalName(t, base, moduleSuffix))

proc taggedName*(base, tag, ns: string): string =
  ## For the callers that keep a counter of their own and additionally own a
  ## PASS LETTER: the letter joins the identifier alongside the namespace, so
  ## the disambiguator stays a number and nothing else (#2457). `intramodinliner`
  ## is the one caller; upstream spells its own the same way (`` result`i.5 ``).
  result = base
  if tag.len > 0:
    result.add LocalNsSep
    result.add tag
  if ns.len > 0:
    result.add LocalNsSep
    result.add ns

type
  Pass* = object
    n*: Cursor         ## Current read position in buf
    buf*: TokenBuf     ## Input buffer for current pass
    dest*: TokenBuf    ## Output buffer being written to
    moduleSuffix*: string  ## Module suffix for symbol generation
    bits*: int         ## number of bits in the target architecture
    namer*: TempNamer  ## Declaration-scoped names for synthesized symbols
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
               firstPassName: string; bits: int): Pass =
  ## Initialize a new Pass pipeline with the given input buffer.
  ## The buffer is moved into the Pass and a cursor is created.
  ## The new pipeline starts with an EMPTY `namer`. A NESTED pipeline (e.g. the
  ## per-coroutine Final-IR run in `treIteratorBody`) must continue the outer
  ## pipeline's counters instead, or its `lowerExprs` re-mints \`x.N SymIds that
  ## collide with still-live outer temps in the same proc (one frame slot,
  ## two types — see tests/nimony/cps/tifexpr_arg_temp_collision.nim); it does
  ## that by `swap`ping its owner's `TempNamer` in around the nested run, which
  ## is O(1) and keeps the counters in exactly one place.
  when not defined(nimony):
    ensurePassTimingInit()
  result = Pass(buf: initialBuf, moduleSuffix: moduleSuffix, bits: bits, passName: firstPassName)
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
