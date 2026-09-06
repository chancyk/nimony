#       Nimony
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Nimony semantic checker.

import std / [parseopt, sets, strutils, os, assertions, syncio]

import ".." / gear2 / modnames
import ".." / lib / [argsfinder, symparser, nifpools, nifreader,
                     nifbuilder, nifindexes, tooldirs, vfs, artifactstore, nimversion, ledger]
import semmain, sem, nifconfig, semos, semdata, indexgen, programs,
       derefs, deps, idetools, cli, langmodes

const
  Usage = "Nimsem Semantic Checker. Version " & Version & """

  (c) 2024-2025 Andreas Rumpf
Usage:
  nimsem [options] [command]
Command:
  m input.nif                 compile a single Nim module to hexer (output and index files derived from input name)
  x file.nif                  generate the .idx.nif file from a .nif file
  e file.nif [dep1.nif ...]   execute the given .nif file
  idetools file1.nif [file2.nif ...]  list usages and definitions

Options:
  -d, --define:SYMBOL       define a symbol for conditional compilation
  -p, --path:PATH           add PATH to the search path
  --compat                  turn on compatibility mode
  --isSystem                passed module is a `system.nim` module
  --isMain                  passed module is the main module of a project
  --noSystem                do not auto-import `system.nim`
  --mm:STRATEGY             select the memory management strategy; the name
                            maps to `system/<strategy>.nim` in the stdlib.
                            Possible values: atomicArc (default), arc
  --bits:N                  `int` has N bits; possible values: 64, 32, 16
  --cpu:SYMBOL              set the target processor (cross-compilation)
  --os:SYMBOL               set the target operating system (cross-compilation)
  --app:console|gui|lib|staticlib
                            set the application type (default: console)
  --base:PATH               set the base directory for the configuration system
  --nimcache:PATH           set the path used for generated files
  --flags:FLAGS             undocumented flags
  --novalidate              skip running the plugin validator on plugin sources
  --verbose                 dump Final IR (and other diagnostics) on contract
                            analysis failures
  --version                 show the version
  --help                    show this help
"""

type
  Command = enum
    None, SingleModule, GenerateIdx, Execute, Idetools, BuildPlugin

proc fail(msg: string): int =
  ## What `quit msg` wrote and returned, as a value: same bytes on stderr, same
  ## exit code, but the process survives so a second module can be checked in
  ## it (`JIT.md` 6.1).
  stderr.writeLine msg
  result = 1

proc processModules(infiles: seq[string]; config: sink NifConfig;
                    moduleFlags: set[ModuleFlag]; commandLineArgs: string): int =
  for infile in infiles:
    if not semos.fileExists(infile):
      return fail("cannot find " & infile)
  var outfiles: seq[string] = @[]
  for infile in infiles:
    # Mirror the doc-mode prefix: `.pc.nif` → `.sc.nif`, plain `.p.nif` → `.s.nif`.
    # Keeps the doc and code-gen caches separate so they don't trample each other.
    let outExt = if infile.endsWith(".pc.nif"): ".sc.nif" else: ".s.nif"
    outfiles.add infile.changeModuleExt(outExt)
  # Cost ledger (JIT.md 5.2): `semcheckToFiles` splits a single module into
  # load, parse, produce, serialize and write (A2a); a cycle group is written
  # as a unit and stays one `produce`. One sample keyed by the first module,
  # with the bytes of all the group's outputs.
  var timer = initPhaseTimer(outfiles[0].parentDir, "nimsem",
                             moduleSuffixOf(outfiles[0]))
  let ok = semcheckToFiles(infiles, outfiles, ensureMove config, moduleFlags,
                           commandLineArgs, false, timer)
  for outfile in outfiles: timer.noteBytes(fileSizeOrZero(outfile))
  timer.finish()
  result = if ok: 0 else: 1

proc executeNif(files: seq[string]; config: sink NifConfig) =
  # file 0 is special as it is the main file. We need to run injectDerefs on it first.
  # The other modules are simply dependencies we need to compile&link too.
  if files.len == 0:
    return

  # little hack: prepare our writenif dependency.
  # Forward `--cc` so the nested nimony's idea of `defined(gcc)` /
  # `defined(clang)` matches the outer nimsem's. Otherwise the nested
  # build sees system.s.nif (already produced by the outer pass under
  # the outer's `--cc` profile) as stale for its own profile and tries
  # to rewrite it — and on Windows that write open fails because the
  # outer nimsem still has the file mmap'd.
  exec quoteShell(findTool("nimony")) & " --nimcache:" & quoteShell(config.nifcachePath) &
    " c " & quoteShell(stdlibFile("std/writenif.nim"))

  var dependencyFiles: seq[string] = @[]
  for i in 1..files.high: dependencyFiles.add files[i]

  buildGraphForEval(
    config = config,
    mainNifFile = files[0],
    dependencyNifFiles = dependencyFiles,
    flags = {},
    moduleFlags = {}
  )

proc runNimsem*(argv: seq[string]): int =
  ## nimsem's command line as a proc: the same parsing, the same messages on
  ## stderr and the same exit code, returned instead of `quit`ed so the tool
  ## can run twice in one process (`JIT.md` 6.1). Call
  ## `semmain.resetFrontendGlobals()` between two runs.
  ##
  ## `--help` and `--version` are the one exception: `cli.parseCommonOption`
  ## still `quit`s for them, and no in-process caller passes them.
  var args: seq[string] = @[]
  var cmd = Command.None
  var forceRebuild = false
  var moduleFlags: set[ModuleFlag] = {}
  var config = initNifConfig("")
  var commandLineArgs = ""
  var p = initOptParser(argv)
  for kind, key, val in getopt(p):
    case kind
    of cmdArgument:
      if cmd == None:
        case key.normalize:
        of "m":
          cmd = SingleModule
        of "x":
          cmd = GenerateIdx
        of "e":
          cmd = Execute
        of "idetools":
          cmd = Idetools
        of "plugin":
          cmd = BuildPlugin
        else:
          return fail("command expected")
      else:
        args.add key

    of cmdLongOption, cmdShortOption:
      var forwardArg = true
      var forwardArgLengc = false  # nimsem doesn't use this, but needed for parseCommonOption
      if parseCommonOption(key, val, config, moduleFlags, forwardArg, forwardArgLengc,
                          helpMsg = Usage, versionMsg = Version & "\n"):
        discard "handled by common CLI parser"
      else:
        case normalize(key)
        of "forcebuild", "f", "ff":
          # Accepted so a hand-run `nimsem m -f` does not die on an unknown
          # option, but never forwarded: `commandLineArgs` is what
          # `semos.runProgram`/`selfExec` splice onto the CTFE sub-compiles,
          # and forcing those throws away a content-addressed cache. Same
          # reasoning as the matching branch in `nimony.nim`.
          forceRebuild = true
          forwardArg = false
        else:
          # `quit(Usage, QuitSuccess)`, minus the quit.
          stderr.writeLine Usage
          return 0
      if forwardArg:
        commandLineArgs.add " --" & key
        if val.len > 0:
          # Raw value: see the matching comment in nimony.nim. These args end
          # up as StringLits in the `.build.nif`, which nifmake quotes once.
          commandLineArgs.add ":" & val

    of cmdEnd: assert false, "cannot happen"
  semos.setupPaths(config)
  if config.linker.len == 0 and config.cc.len > 0:
    config.linker = config.cc
  applyRequestedStore()

  case cmd
  of None:
    result = fail("command missing")
  of SingleModule:
    if args.len < 1:
      result = fail("want at least 1 command line argument")
    else:
      result = processModules(args, ensureMove config, moduleFlags, commandLineArgs)
  of GenerateIdx:
    if args.len != 1:
      result = fail("want exactly 1 command line argument")
    else:
      indexFromNif(args[0])
      result = 0
  of Execute:
    if args.len == 0:
      result = fail("want more than 0 command line argument")
    else:
      executeNif args, ensureMove config
      result = 0
  of BuildPlugin:
    if args.len != 2:
      result = fail("want exactly 2 command line arguments: <plugin.nim> <executable>")
    else:
      buildPlugin(config, args[0], args[1])
      result = 0
  of Idetools:
    if args.len == 0:
      result = fail("want more than 0 command line argument")
    else:
      case config.toTrack.mode
      of TrackUsages, TrackDef:
        usages(args, config)
        result = 0
      of TrackNone:
        result = fail("no --track information provided")

when isMainModule:
  let exitCode = runNimsem(commandLineParams())
  storeFlush()
  when defined(prepMutStats):
    stderr.writeLine "[prepMutStats] fast=", cowFastCount,
      " slow=", cowSlowCount,
      " slowBytes=", cowSlowBytes,
      " cmdline=", commandLineParams().join(" ")
  dumpVfsProfile("nimsem")
  if exitCode != 0: quit exitCode
