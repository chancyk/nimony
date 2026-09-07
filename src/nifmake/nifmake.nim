#       Nifmake tool
# (c) Copyright 2025 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The `nifmake` command line. The build graph itself is `dag.nim`, which
## Nimony links and drives in its own process when the scheduler of JIT.md 6.2
## says a node is not worth a process; this file is what is left when that is
## taken out: option parsing, the help text, and the choice of where the
## report and the profile are written.

import std/[strutils, monotimes, parseopt, syncio]
import ".." / lib / [vfs, artifactstore, nimversion]
import dag

proc writeHelp() =
  echo """nifmake - Nimony build system

Usage:
  nifmake [options] <command> [file]

Commands:
  run <file.nif>        Execute the build graph
  makefile <file.nif>   Generate Makefile from build graph
  help                  Show this help
  version               Show version

Options:
  -j, --parallel[:N]    Parallel builds (for 'run'); :N caps at N processes
  --makefile <name>     Output Makefile name (default: Makefile)
  --force               Force rebuild of all targets (removes their outputs first)
  --rerun               Run every command regardless of staleness, but KEEP the
                        existing outputs, so a tool writing OnlyIfChanged can
                        still report "unchanged" and spare everything
                        downstream. For a caller that knows the results are
                        stale for a reason no input mtime can express — e.g.
                        nimony when the compilation options changed.
  --verbose             Show verbose output
  --base:<dir>          Use <dir> as base directory for `.args` files.
                        If not set, no `.args` files are processed.
  --progress[:LO:HI]    Show a live percentage indicator while building (only
                        on an interactive terminal; ignored with --verbose and
                        --report). The optional LO:HI range remaps the bar so a
                        caller running several builds can show one continuous
                        0..100% bar across them.
  --vfs:MODE            Artifact store policy: disk (default), memory,
                        memory+spill or verify. Normally inherited from the
                        environment, which is how nimony hands it down.
  --vfs-budget:MB       Resident budget for the artifact store (default 512).
  --profile             Print timing profile of executed commands to stderr.
  --report              Print machine-readable per-command invocation
                        counts to stdout, e.g.
                          nifmake-report nimsem=2 hexer=1 total=3 inproc=0
                        `inproc` counts the commands a caller ran without a
                        process; the `nifmake` binary never does, so it is
                        always 0 here. Used by the incremental-build
                        regression test.

Examples:
  nifmake run build.nif
  nifmake makefile build.nif
  nifmake --makefile build.mk makefile build.nif
"""
  quit(0)

proc writeVersion() =
  echo "nifmake " & Version
  quit(0)

type
  CliCommand = enum
    cmdRun, cmdMakefile, cmdHelp, cmdVersion

proc main() =
  var
    cmd = cmdHelp
    inputFile = ""
    outputMakefile = "Makefile"
    opt: set[CliOption] = {}
    baseDir = ""
    progressLo = 0
    progressHi = 100
    maxJobs = 0

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      case key.normalize
      of "help", "h": cmd = cmdHelp
      of "version", "v": cmd = cmdVersion
      of "run": cmd = cmdRun
      of "makefile": cmd = cmdMakefile
      else:
        if inputFile == "":
          inputFile = key
        else:
          quit "Too many arguments"

    of cmdLongOption, cmdShortOption:
      case key.normalize
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "parallel", "j":
        opt.incl Parallel
        # `--parallel:N` / `-j:N` caps the per-depth fan-out at N processes;
        # bare `--parallel` (no value) keeps the all-cores default. Without this
        # the value was discarded and every DAG depth ran on all cores, which
        # OOMs large projects (e.g. nimbus under `nim ic -d:icJobs:N`).
        if val.len > 0:
          try:
            maxJobs = parseInt(val)
          except ValueError:
            quit "invalid value for --parallel: " & val
          if maxJobs < 1: quit "--parallel value must be >= 1"
      of "makefile": outputMakefile = val
      of "force": opt.incl Force
      of "rerun": opt.incl Rerun
      of "verbose": opt.incl Verbose
      of "base": baseDir = val
      of "profile": opt.incl Profile
      of "report": opt.incl Report
      of "vfs":
        if not requestStorePolicy(val):
          quit "invalid value for --vfs; expected disk, memory, memory+spill or verify"
      of "vfs-budget", "vfsbudget":
        let mb = parseBudgetMB(val)
        if mb <= 0: quit "invalid value for --vfs-budget; expected a size in megabytes"
        requestStoreBudgetMB mb
      of "progress":
        opt.incl Progress
        # Optional `--progress:LO:HI` remaps the bar into a sub-range so a
        # multi-phase caller gets one continuous 0..100% indicator.
        if val.len > 0:
          let parts = val.split(':')
          if parts.len == 2:
            try:
              progressLo = parseInt(parts[0])
              progressHi = parseInt(parts[1])
            except ValueError:
              quit "invalid --progress range: " & val
          else:
            quit "invalid --progress range: " & val
      else:
        echo "Unknown option: --", key
        quit(1)

    of cmdEnd: discard

  applyRequestedStore()

  case cmd
  of cmdHelp: writeHelp()
  of cmdVersion: writeVersion()
  of cmdRun:
    if inputFile == "":
      quit "Input file required for 'run' command"

    if Profile in opt or Report in opt:
      var profile = initProfileData()
      let parseStart = getMonoTime()
      var d = parseNifFile(inputFile, baseDir)
      profile.parseTime = toSeconds(getMonoTime() - parseStart)
      let ok = runDag(d, opt, addr profile, progressLo, progressHi, maxJobs)
      if Profile in opt: stderr.write profileText(profile)
      if Report in opt: stdout.write reportLine(profile)
      if not ok: quit 1
    else:
      var d = parseNifFile(inputFile, baseDir)
      if not runDag(d, opt, nil, progressLo, progressHi, maxJobs):
        quit 1

  of cmdMakefile:
    if inputFile == "":
      quit "Input file required for 'makefile' command"

    let d = parseNifFile(inputFile, baseDir)
    generateMakefile(d, outputMakefile)
    echo "Generated: ", outputMakefile

when isMainModule:
  main()
  storeFlush()
  dumpVfsProfile("nifmake")
