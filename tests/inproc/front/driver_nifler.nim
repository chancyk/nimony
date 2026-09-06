## Runs `nifler.runNifler` twice in ONE process, with `resetNiflerGlobals()`
## between the runs. The runner (`../setup.nim`) compares what this leaves
## behind with what two `bin/nifler` processes leave behind.
##
## Argv: one file holding the two argument vectors, one argument per line,
## the two runs separated by a blank line. A file rather than this program's
## own command line so an argument may contain anything a path may contain.

import std / [os, strutils, syncio]
import "../../../src/nifler/nifler"

proc readRuns(path: string): seq[seq[string]] =
  result = @[@[]]
  for raw in lines(path):
    let line = raw.strip(leading = false, chars = {'\r', '\n'})
    if line.len == 0: result.add @[]
    else: result[^1].add line
  while result.len > 0 and result[^1].len == 0: discard result.pop()

let runs = readRuns(paramStr(1))
for i, argv in runs:
  if i > 0: resetNiflerGlobals()
  let code = runNifler(argv)
  if code != 0:
    stderr.writeLine "run " & $i & " exited with " & $code
    quit 1
