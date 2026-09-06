import std/[syncio, assertions]

# A `seq[string]` result: the sub-compile's serializer walks the seq's
# `data: ptr UncheckedArray[string]` field element-wise, and each element is
# itself a string — `unravel`'s `isSomeStringType` entry point rather than an
# object walk. Two indirections in one value, which the `seq[int]` test does
# not reach.

proc words(): seq[string] =
  result = @[]
  result.add "alpha"
  result.add "beta"
  result.add "gamma"

const w: seq[string] = words()

assert w.len == 3
assert w[0] == "alpha"
assert w[2] == "gamma"

const lit: seq[string] = @["one", "two"]
assert lit.len == 2
assert lit[1] == "two"

echo w[0], "/", w[1], "/", w[2]
echo lit.len
