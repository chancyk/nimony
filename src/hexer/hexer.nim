#
#
#           Hexer Compiler
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

##[

Hexer
------

Hexer is our middle-end. It transforms Nimony code into NIFC code. This requires
multiple different steps.

- Iterator inlining.
- Lambda lifting.
- Inject dups.
- Lower control flow expressions to control flow statements (eliminate the expr/nkStmtListExpr construct).
- Inject destructors.
- Map builtins like `new` and `+` to "compiler procs".
- Translate exception handling.


NIFC generation
~~~~~~~~~~~~~~~

- It copies used imported symbols into the current NIF file. As a fix point operation
  until no foreign symbols are left.
- `importc`'ed symbols are replaced by their `.c` variants.
- `importc`'ed symbols might lead to `(incl "file.h")` injections.
- Nim types must be translated to NIFC types.
- Types and procs must be moved to toplevel statements.


Grammar
-------

Hexer accepts Nimony's grammar.

]##

import std / [parseopt, strutils, os, osproc, tables, assertions, syncio]
import ".." / nimony / [langmodes, nifconfig]
import lengcgen, lifter, duplifier, destroyer, inliner, constparams, dce2
import hexerio
import ".." / lib / [vfs, artifactstore, nimversion, ledger]
from ".." / nimony / programs import prog, Program
from ".." / lib / nifpools import pool, newPool, fallbackPool
from intramodinliner import resetInlinerStats

include ".." / lib / compat2

const
  Usage = "Hexer Compiler. Version " & Version & """

  (c) 2024-2025 Andreas Rumpf
Usage:
  hexer [options] [command]
Command:
  c file.nif                compile semchecked NIF file to Leng
  d file1.nif file2.nif ... perform dead code elimination for the given NIF files

Options:
  --bits:N                  `int` has N bits; possible values: 64, 32, 16
  --os:NAME                 target operating system (default: the host's)
  --outdir:DIR              (d only) write .c.nif outputs to DIR
  --isMain                  mark the file as the main module
  --native                  target the native backend (arkham+nifasm, no C)
  --app:TYPE                application type: console, gui, lib, staticlib (default: console)
  --flags:FLAGS             undocumented flags
  --version                 show the version
  --help                    show this help
"""

proc emitLine(msg: string) =
  ## The output half of `quit(msg, code)`: the message, then a newline, on
  ## stderr. `runHexer` returns the code instead of exiting, so the two halves
  ## are separated -- but the bytes and the codes stay what the CLI printed
  ## before A2a.
  write stderr, msg
  write stderr, "\n"

proc writeHelp(): int =
  emitLine Usage
  result = QuitSuccess

proc writeVersion(): int =
  emitLine(Version & "\n")
  result = QuitSuccess

proc fail(msg: string): int =
  emitLine msg
  result = QuitFailure

proc resetHexerGlobals*() =
  ## Put the process back into the state a freshly started `hexer` is in, so
  ## that `runHexer` can be called again (JIT_IMPL.md A2a, JIT.md 6.1). Call
  ## it BETWEEN two in-process runs, never in the middle of one.
  ##
  ## What it resets, and why each one is here:
  ##
  ## - `programs.prog` (`src/nimony/programs.nim:73`). The only shared global
  ##   whose stale content can change hexer's OUTPUT. `setupProgram` writes
  ##   `prog.main` and adds `prog.mods[main]`, but never clears either, so a
  ##   second run would answer `load(suffix)`/`tryLoadSym` out of run 1's
  ##   `prog.mods`/`prog.mem` -- run 1's bytes for a file that changed on disk
  ##   in between. `prog` is reset here rather than in `src/nimony` because
  ##   A2a-hexer may not edit that file; A2a-front's `resetFrontendGlobals`
  ##   owns the same variable and this call becomes a call to it once it
  ##   exists.
  ## - `nifpools.pool` and, in lockstep, `nifcore.fallbackPool`
  ##   (`src/lib/nifpools.nim:76`, `src/lib/nifcore.nim:445`). Interning the
  ##   same name twice gives the same `SymId`, so the pool looks harmless to
  ##   share -- but the id a name gets depends on how many names were interned
  ##   BEFORE it, and `.dce.nif` and `.live.nif` serialize `HashSet[SymId]` /
  ##   `Table[_, SymId]` in hash order. A second run over a warm pool therefore
  ##   writes the same set of symbols in a different ORDER than a fresh process
  ##   does. That is exactly what the `tests/inproc/hexer` comparison catches,
  ##   and it is why JIT.md 6.1 names `pool` in the reset set.
  ##
  ##   The hazard this creates for A2b, stated plainly: `src/nimony/
  ##   identstyle.nim`'s `styleGroups` / `styleHighWaterMark` /
  ##   `pragmaStyleIndex` cache `StrId`s of the pool they were built over, and
  ##   nothing here can reach them. Hexer never consults them (they are sem's),
  ##   so this reset is correct for hexer -- but a process that runs sem again
  ##   after a hexer phase must go through A2a-front's `resetFrontendGlobals`,
  ##   which owns `pool` and has to clear identstyle with it. Listed in
  ##   `notes/a2a-hexer.md`.
  ## - `intramodinliner.inlinerStats` (`src/hexer/intramodinliner.nim:1270`,
  ##   `-d:inlinerStats` only): a per-callee splice counter that would
  ##   otherwise report run 1 + run 2 as one number.
  ##
  ## Everything else in `src/hexer` is per-run by construction: `EContext`,
  ## `Pass`, `Con`, `LiftingCtx`, `InlinerCtx` and every pass `Context` are
  ## built fresh inside the call that uses them (AGENTS.md's explicit state
  ## objects), and a `grep` for a module-level `var` over `src/hexer/*.nim`
  ## finds nothing else.
  ##
  ## What it deliberately does NOT reset, each for a stated reason:
  ##
  ## - `passes.nim`'s `passTimingInited` / `passTimingLog` / `passTimingEnabled`
  ##   (`src/hexer/passes.nim:32-35`): the `NIMONY_PASS_TIMING` append log is
  ##   process-lifetime by design -- its own comment says several pipelines
  ##   share one file -- and closing and reopening it per run would cost a
  ##   syscall pair and buy nothing. A caller that wants a different log per
  ##   run has to use a different process.
  ## - `nifpools.globalTags` / `nifcore.fallbackTags`: the tag pool is seeded
  ##   from the master `TagEnum` so a tag's id is its ordinal, the handful of
  ##   tags hexer registers by name on top (`imp`, `uses`, `roots`, `offers`,
  ##   `live`, `resolved`, `mod`) always get the same ids in the same order,
  ##   and no `TagId` is ever hashed into a serialized set. Nothing to fix, and
  ##   `createMasterTagPool` is private to `nifpools` anyway.
  ## - `artifactstore.store` and the seven `vfs` relays: the store is the
  ##   CALLER's policy (`--vfs`), installed once per process. Tearing it down
  ##   between two in-process phases would drop the caller's cache; A2b calls
  ##   `uninstallArtifactStore` itself when it wants that.
  ## - `artifactstore.request` (the parsed `--vfs` flag): private to that
  ##   module and not resettable from here. A second `runHexer` that passes no
  ##   `--vfs` therefore inherits the first one's policy; the wanted shared
  ##   change is in `notes/a2a-hexer.md`.
  prog = default(Program)
  pool = newPool()
  fallbackPool = pool
  resetInlinerStats()

proc runHexer*(args: seq[string]): int =
  ## The whole CLI as a proc (JIT_IMPL.md A2a). Returns the process exit code
  ## instead of calling `quit`, so A2b's phase registry can run hexer in the
  ## caller's process. Messages and codes are the ones the CLI printed before:
  ## a diagnostic goes to stderr with a trailing newline and answers 1, `--help`
  ## and `--version` answer 0.
  ##
  ## Call `resetHexerGlobals()` between two invocations in the same process.
  var files: seq[string] = @[]
  var bits = sizeof(int) * 8
  var bigEndian = false
  var flags = DefaultSettings
  var outdir = ""
  var action = ""
  var isMain = false
  var native = false
  var appType = appConsole
  var isWindows = defined(windows)
  for kind, key, val in getopt(args):
    case kind
    of cmdArgument:
      if action.len == 0:
        action = key.normalize
      else:
        files.add key
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "bits":
        case val
        of "64": bits = 64
        of "32": bits = 32
        of "16": bits = 16
        else: return fail "invalid value for --bits"
      of "cpu":
        case val
        of "be": bigEndian = true
        of "le": bigEndian = false
        else: return fail "invalid value for --cpu; expected 'be' or 'le'"
      of "os":
        # Only the Windows/not-Windows distinction reaches the code generator:
        # a Windows entry point receives no argc/argv/envp (see `genMainProc`).
        isWindows = normalize(val) == "windows"
      of "outdir":
        outdir = val
      of "ismain":
        isMain = true
      of "native":
        native = true
      of "app":
        case normalize(val)
        of "console": appType = appConsole
        of "gui": appType = appGui
        of "lib": appType = appLib
        of "staticlib": appType = appStaticLib
        else: return fail "invalid value for --app; expected console, gui, lib, or staticlib"
      of "flags":
        flags = parseFlags(val)
      of "vfs":
        if not requestStorePolicy(val):
          return fail "invalid value for --vfs; expected disk, memory, memory+spill or verify"
      of "vfs-budget", "vfsbudget":
        let mb = parseBudgetMB(val)
        if mb <= 0: return fail "invalid value for --vfs-budget; expected a size in megabytes"
        requestStoreBudgetMB mb
      of "help", "h": return writeHelp()
      of "version", "v": return writeVersion()
      else: return writeHelp()
    of cmdEnd: assert false, "cannot happen"
  applyRequestedStore()
  if action == "c" and files.len > 1:
    return fail "too many arguments given, seek --help"
  elif action.len == 0 or files.len == 0:
    return writeHelp()
  else:
    # Cost ledger (JIT.md 5.2): one fragment per (phase, module), written into
    # the directory this invocation produces its artifacts in. Since A2a the
    # phase procs are split into load/parse/produce/serialize/write, so every
    # bucket the ledger carries is filled by the `note*` calls inside the
    # path-based wrappers rather than everything landing in `produce`.
    #
    # `status` is how a phase reports an I/O failure it used to `quit` on, so
    # that a library caller keeps its process. The message and the code are
    # the ones the CLI printed before A2a, and a failed run publishes no
    # ledger fragment -- the pre-A2a code quit before `timer.finish`, and a
    # phase that did not produce its output must not move its average.
    var status = HexerStatus(msg: "")
    case action
    of "c":
      let dir = if outdir.len > 0: outdir else: files[0].parentDir
      var timer = initPhaseTimer(dir, "hexer", moduleSuffixOf(files[0]))
      expand files[0], bits, bigEndian, flags, isMain, outdir, timer, status,
             appType, native, isWindows
      if status.failed: return fail status.msg
      timer.noteOutput(dir / moduleSuffixOf(files[0]) & ".x.nif")
      timer.finish()
    of "d":
      deadCodeElimination(files, outdir, status)
      if status.failed: return fail status.msg
    of "dl":
      # Compute the global live set + resolve table from a list of
      # per-module `.dce.nif` analyses. Last argument is the output
      # `.live.nif`; all preceding arguments are the input `.dce.nif`s.
      if files.len < 2:
        return fail "dl: expected <dce-file>... <live-output>"
      var timer = initPhaseTimer(files[^1].parentDir, "dceLive", "")
      computeLiveSet(files.toOpenArray(0, files.len - 2), files[^1], timer)
      timer.noteOutput(files[^1])
      timer.finish()
    of "de":
      # Per-module emit. Args: <M.x.nif> <main.live.nif>; outputs
      # <outdir>/<M>.c.nif.
      if files.len != 2:
        return fail "de: expected <x.nif> <live.nif>"
      let dir = if outdir.len > 0: outdir else: files[0].parentDir
      var timer = initPhaseTimer(dir, "dceEmit", moduleSuffixOf(files[0]))
      dceEmit(files[0], files[1], outdir, timer, status)
      if status.failed: return fail status.msg
      timer.noteOutput(dir / moduleSuffixOf(files[0]) & ".c.nif")
      timer.finish()
    else:
      return writeHelp()
  result = QuitSuccess

proc handleCmdLine*() =
  ## The CLI shell over `runHexer`.
  let code = runHexer(commandLineParams())
  if code != QuitSuccess: quit code

when isMainModule:
  handleCmdLine()
  storeFlush()
  dumpVfsProfile("hexer")
