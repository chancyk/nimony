## Runs `nimsem.runNimsem` twice in ONE process, with
## `semmain.resetFrontendGlobals()` between the runs — the reset the A2b
## scheduler will make before every in-process phase. The runner
## (`../setup.nim`) compares what this leaves behind with what two `bin/nimsem`
## processes leave behind, byte for byte: an interned symbol id or a pool
## ordering that leaked from the first module into the second would show up
## right there, in the `.s.nif`.
##
## Without the reset this test does not merely drift, it fails: the second run
## finds the first module still in `programs.prog.mods` — registered there as a
## MAIN module, i.e. with no interface tables — and reports every symbol it
## imports from it as undeclared.
##
## Argv: one file holding the two argument vectors, one argument per line,
## the two runs separated by a blank line.

import std / [os, strutils, syncio]
import "../../../src/nimony/nimsem"
import "../../../src/nimony/semmain"

proc readRuns(path: string): seq[seq[string]] =
  result = @[@[]]
  for raw in lines(path):
    let line = raw.strip(leading = false, chars = {'\r', '\n'})
    if line.len == 0: result.add @[]
    else: result[^1].add line
  while result.len > 0 and result[^1].len == 0: discard result.pop()

let runs = readRuns(paramStr(1))
for i, argv in runs:
  if i > 0: resetFrontendGlobals()
  let code = runNimsem(argv)
  if code != 0:
    stderr.writeLine "run " & $i & " exited with " & $code
    quit 1
