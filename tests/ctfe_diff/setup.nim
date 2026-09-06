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
  # A2b: the same corpus with every build-graph node in its own process
  # (`--spawn:always`, the escape hatch) against the default, where nimony
  # calls nimsem, hexer and lengc as procs in its own address space. What this
  # pair is really comparing is a fresh process per phase against a reset of
  # the globals a phase leaves behind (`resetFrontendGlobals`), so a reset that
  # misses one shows up here as a differing `.out.nif` -- and a compile-time
  # evaluation is where it would show up first, since the sub-program is
  # produced by the very phases being reset.
  failures += ctfeDiff(@["tests/nimony/consteval"], "--spawn:always", "")
  # B2: the same corpus with the sub-program COMPILED AND LINKED against the
  # same sub-program RUN FROM NIMSEM'S OWN MEMORY. Two entirely different ways
  # of producing a `.out.nif`, so this is the strongest statement the harness
  # can make about the engine. Only when nimsem has one: without the sibling
  # `../nativenif` checkout there is no engine to compare against, `--ctfe:engine`
  # falls back to the subprocess for every evaluation, and the run would pass
  # while proving nothing -- so say so instead.
  if engineIsCompiledIn():
    failures += ctfeDiff(@["tests/nimony/consteval"], "--ctfe:subprocess", "--ctfe:engine")
  else:
    echo "ctfe_diff: nimsem has no compile-time-evaluation engine " &
         "(no ../nativenif at build time); skipping the --ctfe comparison"

if failures > 0:
  echo "ctfe_diff: ", failures, " failure(s)"
  quit 1
echo "ctfe_diff: all checks passed"
