## Custom runner for the CTFE differential harness: compiles every consteval
## test twice under two sets of nimony flags and asserts that compile-time
## evaluation produced identical `*.out.nif` bytes and identical program output
## both times. Needs a built `bin/nimony` (the tree walk's `tests/setup.hastur`
## provides it).
##
## The two modes are empty strings today because the flags they will name do
## not exist yet: A1b adds `--vfs:disk` / `--vfs:memory+spill`, B2 adds
## `--ctfe:subprocess` / `--ctfe:engine`. Disk against disk is not a vacuous
## run — it is the harness's own baseline, and it catches nondeterminism in the
## sub-compile (a hash-order-dependent Table layout, a leaked absolute path, a
## timestamp) that would otherwise be blamed on whichever mode lands next.
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
  failures += ctfeDiff(@["tests/nimony/consteval"], "", "")

if failures > 0:
  echo "ctfe_diff: ", failures, " failure(s)"
  quit 1
echo "ctfe_diff: all checks passed"
