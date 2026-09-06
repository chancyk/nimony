## Custom runner for the CTFE differential harness: compiles every consteval
## test twice under two sets of nimony flags and asserts that compile-time
## evaluation produced identical `*.out.nif` bytes and identical program output
## both times. Needs a built `bin/nimony` (the tree walk's `tests/setup.hastur`
## provides it).
##
## The two modes are `--vfs:disk` and `--vfs:memory+spill` since A1b: the
## first is the escape hatch that installs no artifact store at all, the second
## keeps every artifact resident in the process that produced it. B2 will add
## `--ctfe:subprocess` / `--ctfe:engine` the same way. The comparison also
## still catches nondeterminism in the sub-compile itself (a hash-order-
## dependent Table layout, a leaked absolute path, a timestamp), which is what
## made a disk-against-disk run worth having before these flags existed.
## `ctfeDiffSelfTest` is what proves the comparison has teeth: it must report a
## planted difference and must not report an identical pair.

import std / [os, strutils]
import "../../src/hastur/kit"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")

var failures = ctfeDiffSelfTest()
if failures > 0:
  echo "ctfe_diff: the harness self-test failed; the comparison below proves nothing"

# `--self-test` runs only the harness's own check, which takes milliseconds —
# the way to iterate on `ctfediff.nim` without paying for two full compiles of
# the corpus.
if "--self-test" notin commandLineParams():
  failures += ctfeDiff(@["tests/nimony/consteval"], "--vfs:disk", "--vfs:memory+spill")

if failures > 0:
  echo "ctfe_diff: ", failures, " failure(s)"
  quit 1
echo "ctfe_diff: all checks passed"
