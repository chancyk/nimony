import std/[syncio, assertions]

# A `sizeof`-dependent value. `sizeof` itself is folded in-process by
# `expreval` (through `semGetSize`, which needs a live SemContext) — but the
# proc call around it is not, so the folded size has to be substituted into
# the expression *before* the sub-compile is synthesised, and the sub-compile
# then computes with it. Both halves in one const.

type
  Pair = object
    a, b: int32
  Wide = object
    tag: int32
    payload: array[4, int64]

proc slotsFor(bytes, unit: int): int =
  result = 0
  var used = 0
  while used < bytes:
    used += unit
    inc result

const pairSize = sizeof(Pair)
assert pairSize == 8

const slots = slotsFor(sizeof(Wide), sizeof(Pair))
assert slots == 5

const widePerPair = sizeof(Wide) div sizeof(int32)
assert widePerPair == 10

proc describeSize(n: int): string =
  result = "bytes="
  result.add $n

const desc = describeSize(sizeof(Pair) * 2)
assert desc == "bytes=16"

echo pairSize, " ", slots, " ", widePerPair
echo desc
