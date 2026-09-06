import std/[syncio, assertions]

# TODO: a `distinct` result does not survive the sub-compile today.
#
# `entryPoint` wraps the value in `(conv <distinct type>)` and then recurses
# with `typ.childCursor` — but it hands the recursion the ORIGINAL, still
# distinct-typed argument, so the generated call is `writeNifInt(walk(0))`
# with `walk(0): Meters`. sem rejects it:
#
#   Error: Type mismatch at [position]
#   writeNifInt(walk(0))
#   [1] expected: int64 but got: Meters (declared in lib/std/writenif.nim(29, 1))
#
# A distinct *string* fails one step earlier, because `unravel`'s
# `isSomeStringType(orig)` short-circuit fires before the DistinctT case:
#
#   [1] expected: string but got: Tag (declared in lib/std/writenif.nim(67, 1))
#
# The fix is a conversion to the base type around `arg` in `entryPoint`'s
# DistinctT/RangetypeT branch.

type
  Meters = distinct int
  Tag = distinct string

proc `+`(a, b: Meters): Meters {.inline.} = Meters(int(a) + int(b))
proc `==`(a, b: Meters): bool {.inline.} = int(a) == int(b)
proc `==`(a, b: Tag): bool {.inline.} = string(a) == string(b)

proc walk(steps: int): Meters =
  result = Meters(0)
  for i in 1 .. steps:
    result = result + Meters(i)

proc label(prefix: string; n: int): Tag =
  var s = prefix
  s.add "-"
  s.add $n
  result = Tag(s)

const d = walk(4)
assert d == Meters(10)

const t = label("node", 7)
assert t == Tag("node-7")

echo int(d)
echo string(t)
