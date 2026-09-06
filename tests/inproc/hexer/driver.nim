## In-process hexer driver — a fixture of `tests/inproc/hexer/setup.nim`, not
## a test of its own. `walk.collectTests` stops at a directory's `setup.nim`
## and never looks at the other `.nim` files there, so this file is only ever
## compiled by that runner.
##
## It does in ONE process what the runner does with five `bin/hexer`
## processes: `hexer c` on two different modules, `hexer dl`, `hexer de` on
## two different modules, and finally the buffer-level `expand` overload —
## with `resetHexerGlobals()` between every pair. The runner then compares the
## bytes. That is the whole point of phase A2a: the in-process path has to be
## byte-for-byte the process path, or A2b cannot use it.

import std / [os, syncio, strutils]

import "../../../src/hexer/hexer"
import "../../../src/hexer/lengcgen"
import "../../../src/hexer/hexerio"
import "../../../src/hexer/dce1"
import "../../../src/nimony/langmodes"
import "../../../src/nimony/nifconfig"
import "../../../src/lib/vfs"
import "../../../src/lib/ledger"

proc need(code: int; what: string) =
  if code != 0:
    write stderr, "driver: " & what & " returned " & $code & "\n"
    quit 1

let p = commandLineParams()
if p.len != 9:
  write stderr, "driver: expected 9 arguments, got " & $p.len & "\n"
  quit 1

let
  sA = p[0]        ## <nimcache>/<suffixA>.s.nif
  sB = p[1]        ## <nimcache>/<suffixB>.s.nif
  inDir = p[2]     ## where the in-process `c` and `de` runs write
  bufDir = p[3]    ## where the buffer-level `expand` writes
  dceList = p[4]   ## a file holding the `dl` inputs, one path per line
  inLive = p[5]    ## the `.live.nif` the in-process `dl` writes
  refLive = p[6]   ## the `.live.nif` the reference `dl` wrote; input to `de`
  xA = p[7]        ## the reference <suffixA>.x.nif; input to `de`
  xB = p[8]        ## the reference <suffixB>.x.nif; input to `de`

var dceFiles: seq[string] = @[]
for line in lines(dceList):
  let s = line.strip
  if s.len > 0: dceFiles.add s

# --- `hexer c`, twice, on two different modules ----------------------------

need runHexer(@["c", "--outdir:" & inDir, sA]), "c " & sA
resetHexerGlobals()
need runHexer(@["c", "--outdir:" & inDir, sB]), "c " & sB
resetHexerGlobals()

# --- `hexer dl` ------------------------------------------------------------

need runHexer(@["dl"] & dceFiles & @[inLive]), "dl"
resetHexerGlobals()

# --- `hexer de`, twice, on two different modules ---------------------------

need runHexer(@["de", "--outdir:" & inDir, xA, refLive]), "de " & xA
resetHexerGlobals()
need runHexer(@["de", "--outdir:" & inDir, xB, refLive]), "de " & xB
resetHexerGlobals()

# --- the buffer-level `expand` --------------------------------------------
#
# Same module, same options, but through `loadExpandInput` + the `ExpandInput`
# overload + `serializeModule`, so the runner can prove the buffer path and
# the file path render the same bytes.

var t = initPhaseTimer("", "", "")
var input = loadExpandInput(sA, bufDir, sizeof(int) * 8, t)
var r = expand(input, false, DefaultSettings, false,
               appConsole, false, defined(windows))
let dest = bufDir / r.modName & ".x.nif"
let content = serializeModule(r.x, dest)
writeSerialized(content, dest, AlwaysWrite)

# The `.dce.nif` side output is an OBJECT in the buffer path, so write it out
# too: proving it renders the same bytes proves the in-process pipeline can
# skip the file entirely and still agree with the process one.
writeAnalysis(bufDir / r.modName & ".dce.nif", r.dce, "." & r.modName)

write stdout, "driver: ok\n"
