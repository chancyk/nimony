#       Nifler
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Nifler is a simple tool that parses Nim code and outputs NIF code.
## No semantic checking is done and no symbol lookups are performed.

import std / [parseopt, strutils, os, assertions, syncio]
import bridge, configcmd
import ".." / lib / [vfs, artifactstore, nimversion, ledger]

include ".." / lib / compat2

const
  Usage = "Nifler - Tools related to NIF. Version " & Version & """

  (c) 2024 Andreas Rumpf
Usage:
  nifler [options] [command] [arguments]
Command:
  p|parse file.nim [output.nif]         parse project.nim, produce a NIF file
  deps file.nim [output.deps.nif]       produce only the deps file (imports/includes)
  config project.nim [output.cfg.nif]   produce a NIF file representing the
                                        entire configuration of `project.nim`

Options:
  --portablePaths       keep line information portable accross different OSes
  --deps                also produce a <inputfile>.deps.nif file (for 'parse' command)
  --docs                preserve `##` doc comments as NIF comment-meta on decls
  --force, -f           force a rebuild
  --version             show the version
  --help                show this help
"""

proc fail(msg: string; code = 1): int =
  ## What `quit msg` wrote and returned, as a value: same bytes on stderr, same
  ## exit code, but the process survives so it can parse a second file
  ## (`JIT.md` 6.1).
  stderr.writeLine msg
  result = code

proc resetNiflerGlobals*() =
  ## Nifler owns no module-level state: `bridge.parseFile`/`parseToBuf` build a
  ## fresh `ConfigRef` and `IdentCache` per call, the vendored Nim parser
  ## (`nimparser/parser.nim`) declares no globals, and the translation runs out
  ## of a `TranslationContext` value. So there is nothing here to reset, and
  ## two `runNifler` calls in one process already produce what two processes
  ## produce — `tests/inproc/front` proves it byte for byte.
  ##
  ## What nifler shares with the rest of the toolchain is reset elsewhere, on
  ## purpose:
  ##
  ## * `nifpools.pool`/`globalTags` — only the `config` command interns into
  ##   them (`configcmd.sourcesChanged`). Resetting them here would pull the
  ##   rug out from under a nimsem sharing the process, so that belongs to
  ##   `semmain.resetFrontendGlobals`.
  ## * `artifactstore`'s store and the `vfs` relays — process-wide `--vfs`
  ##   policy, with `uninstallArtifactStore` as its own reset.
  ##
  ## One piece of state genuinely cannot be reset: the host Nim compiler's
  ## `ast.gconfig.comments` threadvar, which maps a `PNode`'s *address* to its
  ## doc comment and is never pruned (`compiler/ast.nim` says so). It is
  ## write-only from nifler's side and keyed by addresses of nodes that are
  ## live while they are read, so it costs memory in a long-lived process but
  ## cannot change the output.
  discard

proc runNifler*(argv: seq[string]): int =
  ## nifler's command line as a proc: the same parsing, the same messages on
  ## stderr and the same exit code, returned instead of `quit`ed.
  result = 0
  var action = ""
  var args: seq[string] = @[]
  var forceRebuild = false
  var portablePaths = true # false
  var deps = false
  var preserveDocs = false
  var p = initOptParser(argv)
  for kind, key, val in getopt(p):
    case kind
    of cmdArgument:
      if action.len == 0:
        action = key.normalize
      else:
        args.add key
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      # `quit(x, QuitSuccess)`, minus the quit.
      of "help", "h": return fail(Usage, QuitSuccess)
      of "version", "v": return fail(Version & "\n", QuitSuccess)
      of "force", "f": forceRebuild = true
      of "portablepaths": portablePaths = true
      of "deps": deps = true
      of "docs": preserveDocs = true
      of "vfs":
        if not requestStorePolicy(val):
          return fail("invalid value for --vfs; expected disk, memory, memory+spill or verify")
      of "vfs-budget", "vfsbudget":
        let mb = parseBudgetMB(val)
        if mb <= 0: return fail("invalid value for --vfs-budget; expected a size in megabytes")
        requestStoreBudgetMB mb
      else: return fail(Usage)
    of cmdEnd: assert false, "cannot happen"
  applyRequestedStore()

  case action
  of "":
    result = fail(Usage, QuitSuccess)
  of "p", "parse", "deps":
    if args.len == 0:
      result = fail("'parse' command takes a filename")
    else:
      let inp = args[0]
      let outp = if args.len >= 2: args[1].addFileExt".nif" else: changeFileExt(inp, ".nif")
      let depsNif = outp.changeFileExt(".deps.nif")
      if not forceRebuild and vfsExists(outp) and vfsExists(inp) and
          vfsMtime(outp) > vfsMtime(inp) and
          (not deps or (vfsExists(depsNif) and vfsMtime(depsNif) > vfsMtime(inp))):
        discard "nothing to do"
      else:
        # Cost ledger (JIT.md 5.2). `parseToBuf` reads and parses the source and
        # renders the NIF; that is the phase's `produce` (nifler renders as it
        # walks the AST, so there is no separate serialize step). The write is
        # its own bucket now that it happens out here.
        let depsOnly = action == "deps"
        var timer = initPhaseTimer(outp.parentDir, "nifler", moduleSuffixOf(outp))
        let m = parseToBuf(inp, portablePaths, deps, depsOnly, preserveDocs)
        timer.noteProduce()
        if not m.ok:
          return if m.msg.len > 0: fail(m.msg) else: 1
        writeParsed(m, outp, deps, depsOnly)
        timer.noteWrite()
        timer.noteOutput(outp)
        timer.finish()
  of "config":
    if args.len == 0:
      result = fail("'config' command takes a filename")
    else:
      let inp = args[0]
      let outp = if args.len >= 2: args[1].addFileExt".nif" else: changeFileExt(inp, ".cfg.nif")
      if not forceRebuild and vfsExists(outp) and not sourcesChanged(outp):
        discard "nothing to do"
      else:
        produceConfig inp, outp
  else:
    result = fail("Invalid action: " & action)

when isMainModule:
  let exitCode = runNifler(commandLineParams())
  storeFlush()
  dumpVfsProfile("nifler")
  if exitCode != 0: quit exitCode
