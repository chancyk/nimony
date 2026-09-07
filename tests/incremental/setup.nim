## Custom runner for the incremental-build regression: drives `nimony c
## --report` over `sample.nim` through a fixed sequence of scenarios and
## asserts the per-phase rebuild counts. Needs a built `bin/nimony` (the tree
## walk's `tests/setup.hastur` provides it).
import std / [os, strutils]
import "../../src/hastur/kit"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")

# Once per VFS mode. `--vfs:disk` is the default and is what every other run
# of the suite exercises, so the second pass is the interesting one: the store
# must not change which nodes nifmake considers stale, and the phase counts
# below are the assertion that it does not.
incrementalOCacheTests()
incrementalTests()
incrementalOCacheTests("--vfs:memory+spill")
incrementalTests("--vfs:memory+spill")
# A2b: the same sequence again with every DAG node forced into its own
# process. The counts asserted above are per PHASE, not per process, so they
# must come out the same whether nimony called the phase or spawned it -- which
# is the cheapest possible detector for a scheduler that changed what gets
# rebuilt.
incrementalOCacheTests("--spawn:always")
incrementalTests("--spawn:always")
# ... and the scheduler's own assertions: the `inproc` field, byte identity
# against `--spawn:always`, and a spawn-free compile-time evaluation.
incrementalInprocTests()
# P0c: per-module DCE live sets. A three-module chain small enough that every
# expected `dceEmit`/`cc` count can be named exactly, once per scheduler mode
# (the counts are per PHASE, so they must not depend on who ran the phase).
incrementalLiveTests()
incrementalLiveTests("--spawn:always")
echo "SUCCESS."
