# Fixture for the compile-time-evaluation phases of `incrementalTests`.
#
# Both consts are beyond `expreval`'s in-process folding, so each one makes
# `exprexec` compile and run a program of its own. `label` additionally reads
# a file at RUN time of that program — an ordinary `readFile`, not the `slurp`
# magic — which is the only way the compiler learns about the dependency
# through `std/writenif`'s sidecar.
#
# The test machinery edits `ctfedata.txt` in place and restores it, so
# anything that depends on its exact contents lives in
# `src/hastur/incrementaltests.nim`.

import std / [syncio, strutils]

proc weigh(x: int): int =
  result = 0
  var i = 0
  while i <= x:
    result = result + i
    inc i

const
  label = readFile("ctfedata.txt").splitLines()[0]
  weight = weigh(9)

echo "ctfe label: ", label
echo "ctfe weight: ", weight
