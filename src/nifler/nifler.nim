#       Nifler
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Nifler is a simple tool that parses Nim code and outputs NIF code.
## No semantic checking is done and no symbol lookups are performed.

import std / [parseopt, strutils, os, assertions]
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

proc writeHelp() = quit(Usage, QuitSuccess)
proc writeVersion() = quit(Version & "\n", QuitSuccess)

proc handleCmdLine() =
  var action = ""
  var args: seq[string] = @[]
  var forceRebuild = false
  var portablePaths = true # false
  var deps = false
  var preserveDocs = false
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if action.len == 0:
        action = key.normalize
      else:
        args.add key
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "force", "f": forceRebuild = true
      of "portablepaths": portablePaths = true
      of "deps": deps = true
      of "docs": preserveDocs = true
      of "vfs":
        if not requestStorePolicy(val):
          quit "invalid value for --vfs; expected disk, memory, memory+spill or verify"
      of "vfs-budget", "vfsbudget":
        let mb = parseBudgetMB(val)
        if mb <= 0: quit "invalid value for --vfs-budget; expected a size in megabytes"
        requestStoreBudgetMB mb
      else: quit(Usage)
    of cmdEnd: assert false, "cannot happen"
  applyRequestedStore()

  case action
  of "":
    writeHelp()
  of "p", "parse", "deps":
    if args.len == 0:
      quit "'parse' command takes a filename"
    else:
      let inp = args[0]
      let outp = if args.len >= 2: args[1].addFileExt".nif" else: changeFileExt(inp, ".nif")
      let depsNif = outp.changeFileExt(".deps.nif")
      if not forceRebuild and vfsExists(outp) and vfsExists(inp) and
          vfsMtime(outp) > vfsMtime(inp) and
          (not deps or (vfsExists(depsNif) and vfsMtime(depsNif) > vfsMtime(inp))):
        discard "nothing to do"
      else:
        # Cost ledger (JIT.md 5.2). nifler's load, parse, IR conversion and
        # write all happen inside `parseFile`, so the whole call is the phase's
        # `produce`; splitting it needs the buffer-level entry points of A2a.
        var timer = initPhaseTimer(outp.parentDir, "nifler", moduleSuffixOf(outp))
        parseFile inp, outp, portablePaths, deps, action == "deps", preserveDocs
        timer.noteProduce()
        timer.noteOutput(outp)
        timer.finish()
  of "config":
    if args.len == 0:
      quit "'config' command takes a filename"
    else:
      let inp = args[0]
      let outp = if args.len >= 2: args[1].addFileExt".nif" else: changeFileExt(inp, ".cfg.nif")
      if not forceRebuild and vfsExists(outp) and not sourcesChanged(outp):
        discard "nothing to do"
      else:
        produceConfig inp, outp
  else:
    quit "Invalid action: " & action

when isMainModule:
  handleCmdLine()
  storeFlush()
  dumpVfsProfile("nifler")
