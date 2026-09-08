## The out-of-process guest driver — a fixture of `tests/inproc/guest/setup.nim`,
## not a test of its own. `walk.collectTests` stops at a directory's `setup.nim`
## and never looks at the other `.nim` files there, so this file is only ever
## compiled by that runner.
##
## It is **one** process that runs **several** programs, which is the whole
## claim of JIT_IMPL.md B4 step 1: `engine.runWholeProgram` cannot do that
## without accumulating a parked thread and an unreleasable 256 MB arena per
## run (`hostrun.guestExit` never returns into the guest's frame), and
## `engine.runWholeProgramOutOfProcess` can, because each program gets a
## `nimrun` of its own and the kernel reclaims all of it.
##
## Each program's stdout is redirected onto a file with `dup2` for the duration
## of its run — not captured by a reader, because the loader inherits
## descriptor 1 untouched and that is exactly the property the runner is about
## to compare against a plain `nimony r`.

import std / [os, posix, syncio, strutils, osproc]

import "../../../src/nimony/engine"

type
  Program = object
    ## One program to run: what `nimony r` would have handed
    ## `runWholeProgram`, plus where its stdout goes this time.
    backendDir, mainModule, blobDir, outFile: string

  Driver = object
    ## The whole run's state. One object rather than a pile of locals so that
    ## the report at the end reads off exactly what the runs produced.
    programs: seq[Program]
    statuses: seq[int]
    outcomes: seq[string]
    reasons: seq[string]
    threadsBefore, threadsAfter: int

proc countThreads(): int =
  ## How many threads this process has, or -1 where it cannot be told. The
  ## number IS the phase: in-process every guest that exits parks one forever.
  when defined(linux):
    result = -1
    try:
      for line in lines("/proc/self/status"):
        if line.startsWith("Threads:"):
          return parseInt(line.split()[1])
    except CatchableError, IOError:
      result = -1
  elif defined(macosx):
    let (o, code) = execCmdEx("ps -M " & $getCurrentProcessId() &
                              " | tail -n +2 | wc -l")
    if code != 0: return -1
    try:
      result = parseInt(o.strip)
    except ValueError:
      result = -1
  else:
    result = -1

proc runOne(p: Program; d: var Driver) =
  ## Redirect fd 1 at `p.outFile`, run the program in a loader process, put fd 1
  ## back. `dup`/`dup2` rather than `reopen`, because what has to move is the
  ## DESCRIPTOR the child inherits, and Nim's `stdout` is only a `FILE*` over it.
  flushFile stdout
  let saved = dup(1)
  let fd = open(p.outFile.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
  if fd < 0 or saved < 0:
    write stderr, "driver: cannot redirect stdout to " & p.outFile & "\n"
    quit 1
  discard dup2(fd, 1)
  discard close(fd)

  let r = runWholeProgramOutOfProcess(
    RunProgram(backendDir: p.backendDir, mainModule: p.mainModule,
               argv: @[p.mainModule], verbose: false, profile: false,
               blobCacheDir: p.blobDir))

  flushFile stdout
  discard dup2(saved, 1)
  discard close(saved)

  d.outcomes.add (if r.outcome == roRan: "ran" else: "refused")
  d.statuses.add r.status
  d.reasons.add r.reason

proc main() =
  let a = commandLineParams()
  if a.len < 5 or (a.len - 1) mod 4 != 0:
    write stderr, "driver: <resultFile> then 4 arguments per program\n"
    quit 1
  var d = Driver(programs: @[], statuses: @[], outcomes: @[], reasons: @[],
                 threadsBefore: 0, threadsAfter: 0)
  let resultFile = a[0]
  var i = 1
  while i + 3 < a.len:
    d.programs.add Program(backendDir: a[i], mainModule: a[i+1],
                           blobDir: a[i+2], outFile: a[i+3])
    i += 4

  d.threadsBefore = countThreads()
  for k in 0 ..< d.programs.len:
    runOne(d.programs[k], d)
  d.threadsAfter = countThreads()

  # One line per program, then the two facts the runner asserts about the HOST:
  # it is still here, and it grew no threads. Written to a file rather than to
  # stdout, which belonged to the guests.
  var report = ""
  for k in 0 ..< d.programs.len:
    report.add d.outcomes[k] & " " & $d.statuses[k] & " " & d.reasons[k] & "\n"
  report.add "threads " & $d.threadsBefore & " " & $d.threadsAfter & "\n"
  report.add "alive\n"
  writeFile(resultFile, report)

main()
